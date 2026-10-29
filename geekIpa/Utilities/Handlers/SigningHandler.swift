//
//  SigningHandler.swift
//  geekIpa
//
//  Created by samara on 17.04.2025.
//

import Foundation
import ZsignC
import UIKit
import OSLog

final class SigningHandler: NSObject {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _movedAppPath: URL?
	// using uuid string is the best way to find the
	// app we want to sign, it does not matter what
	// type of app it is
	private var _app: AppInfoPresentable
	private var _options: Options
	private let _uniqueWorkDir: URL
	// the options struct is not gonna decode these so
	// we're just going to do this. If appicon is not
	// specified, we're not going to modify the app
	// icon. If the cert pair is not there, fallback
	// to adhoc signing (if the option is on, otherwise
	// throw an error
	var appIcon: UIImage?
	var appCertificate: CertificatePair?
	
	// MARK: geekIpa 签名过程页回调（新增；默认 nil，FR.signPackageFile 行为不变）
	/// 进度回调（进度 0...1, 当前阶段文案）
	var progressHandler: (@Sendable (Double, String) -> Void)?
	/// 阶段日志回调（级别 INFO/WARN/ERROR/SUCCESS, 消息）
	var stageLogger: (@Sendable (String, String) -> Void)?
	
	init(app: AppInfoPresentable, options: Options = OptionsManager.shared.options) {
		self._app = app
		self._options = options
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("geekIpaSigning_\(_uuid)", isDirectory: true)
		super.init()
	}
	
	func copy() async throws {
		progressHandler?(0.05, "解析 IPA")
		stageLogger?("INFO", "解析 IPA：复制临时副本")
		
		guard let appUrl = Storage.shared.getAppDirectory(for: _app) else {
			stageLogger?("ERROR", "未找到应用包路径")
			throw SigningFileHandlerError.appNotFound
		}

		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		
		let movedAppURL = _uniqueWorkDir.appendingPathComponent(appUrl.lastPathComponent)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_movedAppPath = movedAppURL
		Logger.misc.info("[\(self._uuid)] Moved Payload to: \(movedAppURL.path)")
		stageLogger?("INFO", "临时副本已就绪：\(movedAppURL.lastPathComponent)")
		progressHandler?(0.15, "解析 IPA")
	}
	
	func modify() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
		guard
			let rawInfo = NSDictionary(contentsOf: movedAppPath.appendingPathComponent("Info.plist")),
			let infoDictionary = rawInfo.mutableCopy() as? NSMutableDictionary
		else {
			stageLogger?("ERROR", "Info.plist 解析失败")
			throw SigningFileHandlerError.infoPlistNotFound
		}
		
		// geekIpa：校验证书阶段
		progressHandler?(0.18, "校验证书")
		if _options.signingOption == .default {
			if let cert = appCertificate {
				stageLogger?("INFO", "证书校验通过：\(cert.nickname ?? "未命名证书")")
			} else {
				stageLogger?("ERROR", "未选择证书")
				throw SigningFileHandlerError.missingCertifcate
			}
		}
		stageLogger?("INFO", "Info.plist 解析完成")
		
		if
			let identifier = _options.appIdentifier,
			let oldIdentifier = infoDictionary["CFBundleIdentifier"] as? String
		{
			try await _modifyPluginIdentifiers(old: oldIdentifier, new: identifier, for: movedAppPath)
		}
		
		// geekIpa：应用配置阶段
		progressHandler?(0.30, "应用配置")
		stageLogger?("INFO", "应用配置：写入 Info.plist 修改")
		try await _modifyDict(using: infoDictionary, with: _options, to: movedAppPath)
		
		if let icon = appIcon {
			try await _modifyDict(using: infoDictionary, for: icon, to: movedAppPath)
		}
		
		if let name = _options.appName {
			try await _modifyLocalesForName(name, for: movedAppPath)
		}
		
		// geekIpa：注入 / 移除阶段
		progressHandler?(0.45, "注入 / 移除")
		if !_options.removeFiles.isEmpty {
			stageLogger?("INFO", "按配置移除 \(_options.removeFiles.count) 项：\(_options.removeFiles.joined(separator: ", "))")
			try await _removeFiles(for: movedAppPath, from: _options.removeFiles)
		}
		
		try await _removePresetFiles(for: movedAppPath)
		try await _removeWatchIfNeeded(for: movedAppPath)
		
		if _options.experiment_supportLiquidGlass {
			try await _locateMachosAndChangeToSDK26(for: movedAppPath)
		}
		
		if _options.experiment_replaceSubstrateWithEllekit {
			stageLogger?("WARN", "已启用插件注入：替换 Substrate 为 ElleKit")
			progressHandler?(0.55, "注入 / 移除")
			try await _inject(for: movedAppPath, with: _options)
		} else {
			if !_options.injectionFiles.isEmpty {
				stageLogger?("WARN", "已启用插件注入：\(_options.injectionFiles.count) 个文件")
				progressHandler?(0.55, "注入 / 移除")
				try await _inject(for: movedAppPath, with: _options)
				stageLogger?("INFO", "插件注入完成")
			}
		}
		
		// iOS "26" (19) needs special treatment
		try await _locateMachosAndFixupArm64eSlice(for: movedAppPath)
		
		if _options.mergeEntitlements && _options.appEntitlementsFile == nil {
			try await _mergeEntitlements(for: movedAppPath, with: _options)
		}
		
		let handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)
		try await handler.disinject()
		
		// geekIpa：重签名阶段（签名前取消检查，配合签名过程页的取消语义）
		try Task.checkCancellation()
		progressHandler?(0.70, "重签名")
		stageLogger?("INFO", "重签名：开始")
		
		if
			_options.signingOption == .default,
			appCertificate != nil
		{
			try await handler.sign()
//		} else if _options.signingOption == .adhoc {
//			try await handler.adhocSign()
		} else if _options.signingOption == .onlyModify {
			//
		} else {
			stageLogger?("ERROR", "重签名失败：缺少证书")
			throw SigningFileHandlerError.missingCertifcate
		}
		
		stageLogger?("INFO", "重签名：完成")
		progressHandler?(0.85, "重签名")
		
		// geekIpa：打包输出阶段（写入已签名目录前再检查一次取消，取消则副本直接丢弃）
		try Task.checkCancellation()
		progressHandler?(0.90, "打包输出")
		try await self.move()
		try await self.addToDatabase()
		
		if let error = handler.hadError {
			throw error
		}
	}
	
	func move() async throws {
		guard let movedAppPath = _movedAppPath else {
			throw SigningFileHandlerError.appNotFound
		}
		
		var destinationURL = try await _directory()
		
		try _fileManager.createDirectoryIfNeeded(at: destinationURL)
		
		destinationURL = destinationURL.appendingPathComponent(movedAppPath.lastPathComponent)
		
		try _fileManager.moveItem(at: movedAppPath, to: destinationURL)
		Logger.misc.info("[\(self._uuid)] Moved App to: \(destinationURL.path)")
		stageLogger?("SUCCESS", "已输出已签名副本：\(destinationURL.path)")
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	func addToDatabase() async throws {
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			return
		}
		
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			let bundle = Bundle(url: appUrl)
			
			Storage.shared.addSigned(
				uuid: _uuid,
				source: _app.source,
				certificate: _options.signingOption != .default ? nil : appCertificate,
				appName: bundle?.name,
				appIdentifier: bundle?.bundleIdentifier,
				appVersion: bundle?.version,
				appIcon: bundle?.iconFileName
			) { _ in
				Logger.signing.info("[\(self._uuid)] Added to database")
				// 续签跟踪：证书昵称为 "Apple ID（…）" 前缀的走 7 天免费证书周期
				let isAppleIDSigned = self.appCertificate?.nickname?.hasPrefix("Apple ID（") == true
				RenewalTracker.recordSignedApp(uuid: self._uuid, name: bundle?.name ?? "", kind: isAppleIDSigned ? .appleID : .cert)
				continuation.resume()
			}
		}
		
		
		stageLogger?("INFO", "已写入应用库（已签名）")
		progressHandler?(0.97, "打包输出")
	}
	
	private func _directory() async throws -> URL {
		// Documents/geekIpa/Signed/\(UUID)
		_fileManager.signed(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

extension SigningHandler {
	private func _modifyDict(using infoDictionary: NSMutableDictionary, with options: Options, to app: URL) async throws {
		if options.fileSharing { infoDictionary.setObject(true, forKey: "UISupportsDocumentBrowser" as NSCopying) }
		if options.itunesFileSharing { infoDictionary.setObject(true, forKey: "UIFileSharingEnabled" as NSCopying) }
		if options.proMotion { infoDictionary.setObject(true, forKey: "CADisableMinimumFrameDurationOnPhone" as NSCopying) }
		if options.gameMode { infoDictionary.setObject(true, forKey: "GCSupportsGameMode" as NSCopying)}
		if options.ipadFullscreen { infoDictionary.setObject(true, forKey: "UIRequiresFullScreen" as NSCopying) }
		if options.removeURLScheme { infoDictionary.removeObject(forKey: "CFBundleURLTypes") }
		
		if options.appAppearance != .default {
			infoDictionary.setObject(options.appAppearance.rawValue, forKey: "UIUserInterfaceStyle" as NSCopying)
		}
		if options.minimumAppRequirement != .default {
			infoDictionary.setObject(options.minimumAppRequirement.rawValue, forKey: "MinimumOSVersion" as NSCopying)
		}
		
		if options.experiment_disableLiquidGlass { infoDictionary.setObject(true, forKey: "UIDesignRequiresCompatibility" as NSCopying) }
		if options.experiment_supportLiquidGlass { infoDictionary.setObject(false, forKey: "UIDesignRequiresCompatibility" as NSCopying) }
		
		// useless crap
		if infoDictionary["UISupportedDevices"] != nil {
			infoDictionary.removeObject(forKey: "UISupportedDevices")
		}
		
		// MARK: Prominant values
		
		if let customIdentifier = options.appIdentifier {
			infoDictionary.setObject(customIdentifier, forKey: "CFBundleIdentifier" as NSCopying)
		}
		if let customName = options.appName {
			infoDictionary.setObject(customName, forKey: "CFBundleDisplayName" as NSCopying)
			infoDictionary.setObject(customName, forKey: "CFBundleName" as NSCopying)
		}
		if let customVersion = options.appVersion {
			infoDictionary.setObject(customVersion, forKey: "CFBundleShortVersionString" as NSCopying)
			infoDictionary.setObject(customVersion, forKey: "CFBundleVersion" as NSCopying)
		}
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyDict(using infoDictionary: NSMutableDictionary, for image: UIImage, to app: URL) async throws {
		let imageSizes = [
			(width: 120, height: 120, name: "FRIcon60x60@2x.png"),
			(width: 152, height: 152, name: "FRIcon76x76@2x~ipad.png")
		]
		
		for imageSize in imageSizes {
			let resizedImage = image.resize(imageSize.width, imageSize.height)
			let imageData = resizedImage.pngData()
			let fileURL = app.appendingPathComponent(imageSize.name)
			
			try imageData?.write(to: fileURL)
		}
		
		let cfBundleIcons: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		let cfBundleIconsIpad: [String: Any] = [
			"CFBundlePrimaryIcon": [
				"CFBundleIconFiles": ["FRIcon60x60", "FRIcon76x76"],
				"CFBundleIconName": "FRIcon"
			]
		]
		
		infoDictionary["CFBundleIcons"] = cfBundleIcons
		infoDictionary["CFBundleIcons~ipad"] = cfBundleIconsIpad
		
		try infoDictionary.write(to: app.appendingPathComponent("Info.plist"))
	}
	
	private func _modifyLocalesForName(_ name: String, for app: URL) async throws {
		let localizationBundles = try _fileManager
			.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "lproj" }
		
		localizationBundles.forEach { bundleURL in
			let plistURL = bundleURL.appendingPathComponent("InfoPlist.strings")
			
			guard
				_fileManager.fileExists(atPath: plistURL.path),
				let dictionary = NSMutableDictionary(contentsOf: plistURL)
			else {
				return
			}
			
			dictionary["CFBundleDisplayName"] = name
			dictionary.write(toFile: plistURL.path, atomically: true)
		}
	}
	
	private func _modifyPluginIdentifiers(
		old oldIdentifier: String,
		new newIdentifier: String,
		for app: URL
	) async throws {
		let pluginBundles = _enumerateFiles(at: app) {
			$0.hasSuffix(".app") || $0.hasSuffix(".appex")
		}
		
		for bundleURL in pluginBundles {
			let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
			
			guard let infoDict = NSDictionary(contentsOf: infoPlistURL)?.mutableCopy() as? NSMutableDictionary else {
				continue
			}
			
			var didChange = false
			
			// CFBundleIdentifier
			if let oldValue = infoDict["CFBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["CFBundleIdentifier"] = newValue
					didChange = true
				}
			}
			
			// WKCompanionAppBundleIdentifier
			if let oldValue = infoDict["WKCompanionAppBundleIdentifier"] as? String {
				let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
				if oldValue != newValue {
					infoDict["WKCompanionAppBundleIdentifier"] = newValue
					didChange = true
				}
			}
			if let extensionDict = (infoDict["NSExtension"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
				// NSExtension → NSExtensionAttributes → WKAppBundleIdentifier
				if
					let attributes = extensionDict["NSExtensionAttributes"] as? NSMutableDictionary,
					let oldValue = attributes["WKAppBundleIdentifier"] as? String
				{
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						attributes["WKAppBundleIdentifier"] = newValue
						didChange = true
					}
				}
                
				// NSExtension → NSExtensionFileProviderDocumentGroup
				if
					let oldValue = extensionDict["NSExtensionFileProviderDocumentGroup"] as? String
				{
					let newValue = oldValue.replacingOccurrences(of: oldIdentifier, with: newIdentifier)
					if oldValue != newValue {
						extensionDict["NSExtensionFileProviderDocumentGroup"] = newValue
						didChange = true
					}
				}
                
				infoDict["NSExtension"] = extensionDict
			}
			
			if didChange {
				infoDict.write(to: infoPlistURL, atomically: true)
			}
		}
	}
	
	private func _removePresetFiles(for app: URL) async throws {
		var files = [
			"_CodeSignature", // Fallbaccck for some reason the locate doesnt work
			"embedded.mobileprovision", // Remove this because zsign doesn't replace it
			"com.apple.WatchPlaceholder", // Useless
			"SignedByEsign" // Useless
		].map {
			app.appendingPathComponent($0)
		}
		
		await files += try _locateCodeSignatureDirectories(for: app)
		
		for file in files {
			try _fileManager.removeFileIfNeeded(at: file)
		}
	}
	
	// horrible edge-case
	private func _removeWatchIfNeeded(for app: URL) async throws {
		let watchDir = app.appendingPathComponent("Watch")
		guard _fileManager.fileExists(atPath: watchDir.path) else { return }
		
		let contents = try _fileManager.contentsOfDirectory(at: watchDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
		
		for app in contents where app.pathExtension == "app" {
			let infoPlist = app.appendingPathComponent("Info.plist")
			if !_fileManager.fileExists(atPath: infoPlist.path) {
				try? _fileManager.removeItem(at: app)
			}
		}
	}
	
	private func _removeFiles(for app: URL, from appendingComponent: [String]) async throws {
		let filesToRemove = appendingComponent.map {
			app.appendingPathComponent($0)
		}
		
		for url in filesToRemove {
			try _fileManager.removeFileIfNeeded(at: url)
		}
	}
	
	private func _inject(for app: URL, with options: Options) async throws {
		let handler = TweakHandler(app: app, options: options)
		try await handler.getInputFiles()
	}
	
	private func _locateMachosAndChangeToSDK26(for app: URL) async throws {
		if let url = Bundle(url: app)?.executableURL {
			LCPatchMachOForSDK26(app.appendingPathComponent(url.relativePath).relativePath)
		}
	}
	
	private func _locateCodeSignatureDirectories(for app: URL) async throws -> [URL] {
		_enumerateFiles(at: app) { $0.hasSuffix("_CodeSignature") }
	}
	
	// this is mainly for CydiaSubstrate where it often contains legacy arm64e slices
	// which cause the app to crash when loaded on ios 26+,
	// avoids `(cpu type/subtype in slice (arm64e.old) does not match fat header (arm64e))`
	private func _locateMachosAndFixupArm64eSlice(for app: URL) async throws {
		let machoFiles = _enumerateFiles(at: app) {
			$0.hasSuffix(".dylib") || $0.hasSuffix(".framework")
		}
		
		for fileURL in machoFiles {
			switch fileURL.pathExtension {
			case "dylib":
				LCPatchMachOFixupARM64eSlice(fileURL.path)
			case "framework":
				if
					let bundle = Bundle(url: fileURL),
					let execURL = bundle.executableURL
				{
					LCPatchMachOFixupARM64eSlice(execURL.path)
				}
			default:
				continue
			}
		}
	}
	
	// shit ass code
	private func _mergeEntitlements(for app: URL, with options: Options) async throws {
		guard let appBinPath = Bundle(url: app)?.executableURL else {
			throw SigningFileHandlerError.appNotFound
		}
		
		guard 
			let binaryProfile = LCGetMachOEntitlements(appBinPath.path),
			let binaryEntitlementsDict = (try? PropertyListSerialization.propertyList(
				from: binaryProfile,
				options: [],
				format: nil
			)) as? [String: Any]
		else {
			return
		}
		
		guard 
			let cert = self.appCertificate, 
			let ourEntitlements = CertificateReader(Storage.shared.getFile(.provision, from: cert)).decoded
		else {
			return 
		}
		
		let ourTeamIdentifier = ourEntitlements.TeamIdentifier[0]
		let ourBundleIdentifer = options.appIdentifier ?? _app.identifier
		
		var baseDictionary: [String: Any] = (ourEntitlements.Entitlements ?? [:]).mapValues { $0.value }
		let additionsDictionary: [String: Any] = binaryEntitlementsDict

		
		// replaces wildcards in base entitlements with new application id
		// aggressive approach though, lets just hope this works :)
		if let ourBundleIdentifer {
			func replaceWildcards(in value: Any, with newAppID: String) -> Any {
				if let stringValue = value as? String {
					return stringValue.replacingOccurrences(of: "*", with: newAppID)
				} else if let arrayValue = value as? [Any] {
					return arrayValue.map { replaceWildcards(in: $0, with: newAppID) }
				} else if let dictValue = value as? [String: Any] {
					return dictValue.mapValues { replaceWildcards(in: $0, with: newAppID) }
				} else if let anyCodable = value as? AnyCodable {
					let substituted = replaceWildcards(in: anyCodable.value, with: newAppID)
					return AnyCodable(substituted)
				}
				return value
			}
			
			baseDictionary = baseDictionary.reduce(into: [:]) { result, entry in
				let (key, value) = entry

				if 
					key == "com.apple.developer.associated-domains" ||
					key == "application.identifier"
				{
					result[key] = value
					return
				}

				result[key] = replaceWildcards(
					in: value,
					with: ourBundleIdentifer
				)
			}
		}
		
		// this will not consider app extensions, zsign doesnt have functionality be more specific
		// with provisioning profiles, this works fine for impactors "Only register main bundle" though.
		if let keychainGroups = additionsDictionary["keychain-access-groups"] as? [Any] {
			baseDictionary["keychain-access-groups"] = keychainGroups
		}
		
		let regex = try NSRegularExpression(pattern: "^[A-Z0-9]{10}\\.")
		
		if let groups = baseDictionary["keychain-access-groups"] as? [String] {
			// remove anything that does not match XXXXXXXXXX. (for example, com.apple.token)
			// only XXXXXXXXXX.* is allowed on keychain-access-groups
			let validGroups = groups.filter { group in
				let range = NSRange(location: 0, length: group.utf16.count)
				return regex.firstMatch(in: group, options: [], range: range) != nil
			}
			
			let updatedGroups = validGroups.map { group -> String in
				let range = NSRange(location: 0, length: group.utf16.count)
				if regex.firstMatch(in: group, options: [], range: range) != nil && group.count >= 11 {
					let suffix = group.suffix(from: group.index(group.startIndex, offsetBy: 11))
					return "\(ourTeamIdentifier).\(suffix)"
				}
				return group
			}
			
			baseDictionary["keychain-access-groups"] = updatedGroups
		}
		
		let plistData = try PropertyListSerialization.data(
			fromPropertyList: baseDictionary,
			format: .xml,
			options: 0
		)

		let tempEntitlementsURL = _uniqueWorkDir
			.appendingPathComponent(UUID().uuidString)
			.appendingPathExtension("plist")
		
		try plistData.write(to: tempEntitlementsURL, options: .atomic)
		
		_options.appEntitlementsFile = tempEntitlementsURL
	}
	
	private func _enumerateFiles(at base: URL, where predicate: (String) -> Bool) -> [URL] {
		guard let fileEnum = _fileManager.enumerator(atPath: base.path) else {
			return []
		}
		
		var results: [URL] = []
		
		while let file = fileEnum.nextObject() as? String {
			if predicate(file) {
				results.append(base.appendingPathComponent(file))
			}
		}
		
		return results
	}
}

enum SigningFileHandlerError: Error, LocalizedError {
	case appNotFound
	case infoPlistNotFound
	case missingCertifcate
	case disinjectFailed
	case signFailed
	
	var errorDescription: String? {
		switch self {
		case .appNotFound: "Unable to locate bundle path."
		case .infoPlistNotFound: "Unable to locate info.plist path."
		case .missingCertifcate: "No certificate was specified."
		case .disinjectFailed: "Removing mach-O load paths failed."
		case .signFailed: "Signing failed."
		}
	}
}
