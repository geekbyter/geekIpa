//
//  AppleIDManager.swift
//  geekIpa
//
//  职责：Apple ID 签名模块核心管理器。
//  - GSA 登录（verificationHandler 双重认证回调包装为 async 提供者）
//  - 凭据/会话持久化：密码与 dsid/authToken 存 Keychain（仅当用户勾选「记住凭据」才存密码）；
//    authToken 过期后用已存密码静默重登录，无法静默重登则抛出「需要重新登录」错误
//  - 从配对文件（Documents/pairingFile.plist，与 HeartbeatManager 一致）读取设备真实 UDID
//    并注册到 Apple 开发者后台（不使用 identifierForVendor）
//  - 开发证书复用/创建：私钥与 CSR 由 AltSign 的 ALTCertificateRequest 在 addCertificate 内部
//    经 SwiftBridge.CertificatesManager 生成；p12 由 ALTCertificate.encryptedP12Data 导出
//    （同样走 CertificatesManager.createPKCS12）。免费账号证书名额满时，仅当旧证书本地没有
//    对应私钥（即不是本模块在用）才自动撤销后重建，否则抛出 certificateLimitReached 警告错误
//  - AppID 复用/创建（bundleID 不合规字符替换为横线；先 fetchAppIDs 找已存在的直接用，
//    冲突错误直接抛给调用方）与描述文件拉取，产出 p12 + mobileprovision
//
//  实现 AppleIDContracts.swift 中的三个协议：
//  AppleIDSessionProviding / ProvisioningRefreshing / AppIDListing
//

import Foundation
import Combine
import Security
import UIKit
import AltSign
import IDeviceSwift

// MARK: - 错误

/// Apple ID 模块错误（描述均为简体中文，可直接展示给用户）
enum AppleIDError: LocalizedError {
	/// 尚未登录
	case notLoggedIn
	/// 会话已失效且无法静默重登，需要用户重新登录
	case requiresRelogin
	/// 邮箱或密码为空
	case emptyCredentials
	/// 用户在双重认证弹窗中点了取消
	case twoFactorCancelled
	/// Anisette 数据拉取失败
	case anisetteUnavailable
	/// 未录入设备 UDID
	case udidNotConfigured
	/// 配对文件中没有设备 UDID
	case deviceUDIDMissing
	/// 证书名额已满，且现有证书本地在用，未自动撤销
	case certificateLimitReached
	/// 本地证书材料（私钥/证书 PEM）缺失
	case certificateDataMissing
	/// 账号下没有可用团队
	case noTeam
	/// 未知错误
	case unknown

	var errorDescription: String? {
		switch self {
		case .notLoggedIn: return "尚未登录 Apple ID"
		case .requiresRelogin: return "登录状态已失效，请重新登录"
		case .emptyCredentials: return "请输入 Apple ID 和密码"
		case .twoFactorCancelled: return "已取消双重认证"
		case .anisetteUnavailable: return "无法获取 Anisette 数据，请检查网络后重试"
		case .udidNotConfigured: return "尚未录入设备 UDID。请到「设备」页点击 UDID 一行录入（注册设备需要真实 UDID）"
		case .deviceUDIDMissing: return "设备 UDID 无效，请到「设备」页重新录入"
		case .certificateLimitReached: return "证书名额已满，且现有证书正在被本机使用。请先在苹果开发者后台手动撤销旧证书后重试"
		case .certificateDataMissing: return "本地证书数据缺失，请重试"
		case .noTeam: return "该 Apple ID 下没有可用的开发团队"
		case .unknown: return "发生未知错误"
		}
	}
}

// MARK: - 双重认证取消标记

/// 供 authenticate 的 verificationHandler 与 completionHandler 之间共享的取消标记
private final class _TwoFactorCancelFlag {
	var cancelled = false
}

// MARK: - Keychain 辅助

private enum _Keychain {
	static func save(_ data: Data, service: String, account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account
		]
		SecItemDelete(query as CFDictionary)
		var attributes = query
		attributes[kSecValueData as String] = data
		attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
		SecItemAdd(attributes as CFDictionary, nil)
	}

	static func load(service: String, account: String) -> Data? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		guard status == errSecSuccess else { return nil }
		return result as? Data
	}

	static func delete(service: String, account: String) {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: account
		]
		SecItemDelete(query as CFDictionary)
	}

	static func saveString(_ string: String, service: String, account: String) {
		guard let data = string.data(using: .utf8) else { return }
		save(data, service: service, account: account)
	}

	static func loadString(service: String, account: String) -> String? {
		guard let data = load(service: service, account: account) else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

// MARK: - AppleIDManager

final class AppleIDManager: ObservableObject {
	static let shared = AppleIDManager()

	// MARK: 常量

	/// 伪装 Xcode 版本（苹果侧只做存在性校验）
	private static let xcodeVersion = "16.0"

	/// Keychain service 标识
	private static let keychainPassword = "com.geekipa.appleid.password"
	private static let keychainSession = "com.geekipa.appleid.session"
	private static let keychainCertKey = "com.geekipa.appleid.certkey"
	private static let keychainCertPEM = "com.geekipa.appleid.cert"
	private static let keychainP12Password = "com.geekipa.appleid.p12password"

	/// UserDefaults 键
	private static let defaultsEmail = "geekIpa.AppleID.email"
	private static let defaultsName = "geekIpa.AppleID.name"
	private static let defaultsFirstName = "geekIpa.AppleID.firstName"
	private static let defaultsLastName = "geekIpa.AppleID.lastName"
	private static let defaultsPersonID = "geekIpa.AppleID.personID"
	private static let defaultsTeamName = "geekIpa.AppleID.teamName"
	private static let defaultsTeamID = "geekIpa.AppleID.teamID"
	private static let defaultsCertSerial = "geekIpa.AppleID.certSerial"
	private static let defaultsCertExpiry = "geekIpa.AppleID.certExpiry"

	/// 内存会话免校验复用窗口（秒）
	private static let sessionReuseInterval: TimeInterval = 600

	// MARK: 界面可观察状态

	@Published private(set) var isLoggedIn = false
	@Published private(set) var accountEmail: String?
	@Published private(set) var accountName: String?
	@Published private(set) var teamName: String?
	@Published private(set) var certificateExpiry: Date?
	@Published private(set) var deviceIsRegistered = false

	/// 证书剩余有效天数（界面展示用）
	var certificateRemainingDays: Int? {
		guard let certificateExpiry else { return nil }
		return Calendar.current.dateComponents([.day], from: Date(), to: certificateExpiry).day
	}

	// MARK: 内存状态

	private var _session: ALTAppleAPISession?
	private var _sessionValidatedAt: Date?
	private var _account: ALTAccount?
	private var _team: ALTTeam?
	/// 本次运行期间的记忆密码（未勾选「记住凭据」时，仅用于本次运行内的静默重登）
	private var _sessionPassword: String?

	// MARK: 初始化

	private init() {
		let defaults = UserDefaults.standard
		accountEmail = defaults.string(forKey: Self.defaultsEmail)
		accountName = defaults.string(forKey: Self.defaultsName)
		teamName = defaults.string(forKey: Self.defaultsTeamName)
		certificateExpiry = defaults.object(forKey: Self.defaultsCertExpiry) as? Date
		isLoggedIn = accountEmail != nil

		// 注册到全局服务定位，供 Renewal 等模块取用
		registerAsServices()
	}

	/// 将本模块注册到全局服务定位（AppleIDContracts.swift 中的 GeekIpaServices）。
	/// WIRE: geekIpaApp —— 建议在 App 启动处引用一次 `AppleIDManager.shared`，
	/// 确保其它模块使用 GeekIpaServices 前已完成装配（init 中已自动调用本方法）。
	func registerAsServices() {
		GeekIpaServices.shared.sessionProvider = self
		GeekIpaServices.shared.profileRefresher = self
		GeekIpaServices.shared.appIDLister = self
	}

	// MARK: - 登录 / 登出

	/// Apple ID 登录。
	/// - Parameters:
	///   - appleID: 邮箱（内部会做 trim + 小写处理）
	///   - password: 密码
	///   - rememberCredentials: 是否把密码存入本机钥匙串（用于 authToken 过期后的静默重登）
	///   - twoFactorCodeProvider: 需要双重认证时由调用方（界面）弹窗取 6 位验证码；返回 nil 表示用户取消
	func login(
		appleID: String,
		password: String,
		rememberCredentials: Bool = false,
		twoFactorCodeProvider: @escaping () async -> String?
	) async throws {
		let email = appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !email.isEmpty, !password.isEmpty else { throw AppleIDError.emptyCredentials }

		let anisette = try await _freshAnisette()

		let (account, session) = try await _authenticate(
			appleID: email,
			password: password,
			anisetteData: anisette,
			twoFactorCodeProvider: twoFactorCodeProvider
		)

		_sessionPassword = password
		_adopt(session: session, account: account, email: email)
		_saveSession(session, for: email)

		let defaults = UserDefaults.standard
		defaults.set(account.firstName, forKey: Self.defaultsFirstName)
		defaults.set(account.lastName, forKey: Self.defaultsLastName)
		defaults.set(account.identifier, forKey: Self.defaultsPersonID)

		if rememberCredentials {
			_Keychain.saveString(password, service: Self.keychainPassword, account: email)
		} else {
			_Keychain.delete(service: Self.keychainPassword, account: email)
		}

		// 拉取团队（尽力而为，失败不影响登录本身）
		try? await _refreshTeam(session: session)
	}

	/// 退出登录：删除本机保存的凭据与会话；已创建的证书私钥保留（证书一年有效，重新登录后可复用）
	func logout() {
		let defaults = UserDefaults.standard
		if let email = accountEmail ?? defaults.string(forKey: Self.defaultsEmail) {
			_Keychain.delete(service: Self.keychainPassword, account: email)
			_Keychain.delete(service: Self.keychainSession, account: email)
		}

		defaults.removeObject(forKey: Self.defaultsEmail)
		defaults.removeObject(forKey: Self.defaultsName)
		defaults.removeObject(forKey: Self.defaultsFirstName)
		defaults.removeObject(forKey: Self.defaultsLastName)
		defaults.removeObject(forKey: Self.defaultsPersonID)
		defaults.removeObject(forKey: Self.defaultsTeamName)
		defaults.removeObject(forKey: Self.defaultsTeamID)
		defaults.removeObject(forKey: Self.defaultsCertSerial)
		defaults.removeObject(forKey: Self.defaultsCertExpiry)

		_session = nil
		_sessionValidatedAt = nil
		_account = nil
		_team = nil
		_sessionPassword = nil

		DispatchQueue.main.async {
			self.isLoggedIn = false
			self.accountEmail = nil
			self.accountName = nil
			self.teamName = nil
			self.certificateExpiry = nil
			self.deviceIsRegistered = false
		}
	}

	// MARK: - 会话（AppleIDSessionProviding）

	/// 获取有效会话：优先复用内存会话；其次用持久化的 dsid/authToken（先调 fetchAccount 校验，
	/// 网络错误不算过期）；authToken 过期则用已存密码静默重登录；都不可行抛 requiresRelogin。
	func validSession() async throws -> ALTAppleAPISession {
		if let session = _session,
		   let validatedAt = _sessionValidatedAt,
		   Date().timeIntervalSince(validatedAt) < Self.sessionReuseInterval {
			return session
		}

		guard let email = accountEmail ?? UserDefaults.standard.string(forKey: Self.defaultsEmail) else {
			throw AppleIDError.notLoggedIn
		}

		let anisette = try await _freshAnisette()

		// 1) 尝试持久化会话
		if let stored = _loadSession(for: email) {
			let candidate = ALTAppleAPISession(
				dsid: stored.dsid,
				authToken: stored.authToken,
				anisetteData: anisette,
				xcodeVersion: Self.xcodeVersion
			)
			do {
				let account = try await _fetchAccount(session: candidate)
				_adopt(session: candidate, account: account, email: email)
				return candidate
			} catch {
				let nsError = error as NSError
				if nsError.domain == NSURLErrorDomain {
					// 网络问题：不当作会话过期，直接抛给调用方
					throw error
				}
				// authToken 已过期，删除后走重登录
				_deleteSession(for: email)
			}
		}

		// 2) 用已存凭据静默重登录（不提供 2FA 回调；若账号强制 2FA 会失败并要求重新登录）
		let password = _Keychain.loadString(service: Self.keychainPassword, account: email) ?? _sessionPassword
		guard let password else {
			throw AppleIDError.requiresRelogin
		}

		do {
			let (account, session) = try await _authenticate(
				appleID: email,
				password: password,
				anisetteData: anisette,
				twoFactorCodeProvider: nil
			)
			_adopt(session: session, account: account, email: email)
			_saveSession(session, for: email)
			return session
		} catch {
			let nsError = error as NSError
			if nsError.domain == NSURLErrorDomain {
				throw error
			}
			// 认证失败（密码可能已改）：清掉已存凭据，要求用户重新登录
			_deleteSession(for: email)
			_Keychain.delete(service: Self.keychainPassword, account: email)
			throw AppleIDError.requiresRelogin
		}
	}

	/// 当前团队（优先免费团队，其次第一个团队）
	func currentTeam() async throws -> ALTTeam {
		if let team = _team { return team }
		let session = try await validSession()
		return try await _refreshTeam(session: session)
	}

	// MARK: - 设备注册

	/// 确保本机已注册到 Apple 开发者后台（UDID 取自已录入的设备信息）
	func ensureDeviceRegistered() async throws {
		let session = try await validSession()
		let team = try await currentTeam()
		let udid = try Self.deviceUDID()
		let deviceType = await Self.currentDeviceType()

		let existing = try await _fetchDevices(team: team, types: [deviceType], session: session)
		if existing.contains(where: { $0.identifier.caseInsensitiveCompare(udid) == .orderedSame }) {
			await MainActor.run { self.deviceIsRegistered = true }
			return
		}

		let name = await Self.sanitizedDeviceName()
		do {
			_ = try await _registerDevice(name: name, udid: udid, type: deviceType, team: team, session: session)
		} catch {
			// 已注册视为成功
			guard Self.altAPIError(from: error) == .deviceAlreadyRegistered else { throw error }
		}
		await MainActor.run { self.deviceIsRegistered = true }
	}

	// MARK: - 开发证书

	/// 确保有可用的 iOS Development 开发证书：本地持有私钥且未过期则复用；否则创建。
	/// 创建时若名额已满，仅自动撤销本地没有私钥的旧证书（本模块未在用的），随后重试一次。


	private func _ensureDevelopmentCertificate(team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
		let remoteCertificates = try await _fetchCertificates(team: team, session: session)
		let now = Date()

		// 1) 复用：远端有效且本地持有对应私钥
		for x509 in remoteCertificates where x509.expiryDate > now {
			let serialKey = Self.normalizedSerial(x509.serialNumber)
			guard let privateKey = _Keychain.load(service: Self.keychainCertKey, account: serialKey) else { continue }
			if x509.data == nil {
				x509.data = _Keychain.load(service: Self.keychainCertPEM, account: serialKey)
			}
			guard x509.data != nil else { continue }
			_saveCertIdentity(serialKey: serialKey, expiry: x509.expiryDate)
			return ALTCertificate(x509: x509, privateKey: privateKey)
		}

		// 2) 创建新证书
		do {
			return try await _createCertificate(team: team, session: session)
		} catch {
			guard Self.altAPIError(from: error) == .tooManyCertificates else { throw error }

			// 免费账号证书名额已满：只撤销本地没有私钥（非本模块在用）的旧证书
			guard let revocable = remoteCertificates.first(where: {
				_Keychain.load(service: Self.keychainCertKey, account: Self.normalizedSerial($0.serialNumber)) == nil
			}) else {
				throw AppleIDError.certificateLimitReached
			}
			_ = try await _revokeCertificate(revocable, team: team, session: session)
			return try await _createCertificate(team: team, session: session)
		}
	}

	private func _createCertificate(team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
		let machineName = await Self.sanitizedDeviceName()
		let certificate = try await _addCertificate(machineName: machineName, team: team, session: session)
		let serialKey = Self.normalizedSerial(certificate.serialNumber)

		// addCertificate 的响应中日期格式不稳定，重新拉一次列表补全过期时间与证书内容
		if let refreshed = try? await _fetchCertificates(team: team, session: session),
		   let match = refreshed.first(where: { Self.normalizedSerial($0.serialNumber) == serialKey }) {
			if match.expiryDate > .distantPast {
				certificate.x509.expiryDate = match.expiryDate
			}
			if certificate.x509.data == nil, match.data != nil {
				certificate.x509.data = match.data
			}
		}

		guard let certPEM = certificate.data else { throw AppleIDError.certificateDataMissing }

		_Keychain.save(certificate.privateKey, service: Self.keychainCertKey, account: serialKey)
		_Keychain.save(certPEM, service: Self.keychainCertPEM, account: serialKey)
		_ = _p12Password(for: serialKey) // 预生成 p12 密码
		_saveCertIdentity(serialKey: serialKey, expiry: certificate.x509.expiryDate)
		return certificate
	}

	// MARK: - 签名管线

	/// 全流程：session → team → 注册设备 → 证书 → AppID → 描述文件，产出签名所需材料。
	/// - Parameters:
	///   - appURL: 待签名应用的本地 URL（预留参数，当前流程不读取其内容）
	///   - bundleID: 原始 bundle identifier（不合规字符会被替换为横线）
	///   - name: App 名称（用于 AppID 名称）
	/// - Returns: p12 数据、p12 密码、mobileprovision 数据
	func signPipeline(
		appURL: URL?,
		bundleID: String,
		name: String
	) async throws -> (p12Data: Data, p12Password: String, mobileprovisionData: Data) {
		let session = try await validSession()
		let team = try await currentTeam()

		// 1) 注册本机设备
		try await ensureDeviceRegistered()

		// 2) 开发证书（复用或创建）+ 导出 p12
		let certificate = try await _ensureDevelopmentCertificate(team: team, session: session)
		guard let certPEM = certificate.data else { throw AppleIDError.certificateDataMissing }
		let serialKey = Self.normalizedSerial(certificate.serialNumber)
		_Keychain.save(certPEM, service: Self.keychainCertPEM, account: serialKey)
		let p12Password = _p12Password(for: serialKey)
		let p12Data = try certificate.encryptedP12Data(password: p12Password)

		// 3) AppID（已存在则直接用）
		let appID = try await _ensureAppID(bundleID: bundleID, name: name, team: team, session: session)

		// 4) 描述文件
		let deviceType = await Self.currentDeviceType()
		let profile = try await ALTAppleAPI.sharedAPI.fetchProvisioningProfile(
			for: appID,
			deviceType: deviceType,
			team: team,
			session: session
		)

		return (p12Data, p12Password, profile.data)
	}

	// MARK: - 描述文件刷新（ProvisioningRefreshing）

	/// 为指定 bundleID 拉取最新描述文件数据（AppID 不存在则自动创建）
	func freshProfileData(bundleIdentifier: String, appName: String) async throws -> Data {
		let session = try await validSession()
		let team = try await currentTeam()
		let appID = try await _ensureAppID(bundleID: bundleIdentifier, name: appName, team: team, session: session)
		let deviceType = await Self.currentDeviceType()
		let profile = try await ALTAppleAPI.sharedAPI.fetchProvisioningProfile(
			for: appID,
			deviceType: deviceType,
			team: team,
			session: session
		)
		return profile.data
	}

	/// 当前 Apple ID 开发证书的 p12 数据与密码（完全使用本地缓存材料，同步可用）
	func currentSigningP12() throws -> (data: Data, password: String) {
		let defaults = UserDefaults.standard
		guard
			let serialKey = defaults.string(forKey: Self.defaultsCertSerial),
			let privateKey = _Keychain.load(service: Self.keychainCertKey, account: serialKey),
			let certPEM = _Keychain.load(service: Self.keychainCertPEM, account: serialKey),
			let password = _Keychain.loadString(service: Self.keychainP12Password, account: serialKey),
			let certificate = ALTCertificate(data: certPEM, privateKey: privateKey)
		else {
			throw AppleIDError.certificateDataMissing
		}
		let p12Data = try certificate.encryptedP12Data(password: password)
		return (p12Data, password)
	}

	// MARK: - AppID 名额管理（AppIDListing）

	/// 列出该 Apple ID 下所有已注册 App ID
	func listAppIDs() async throws -> [ALTAppID] {
		let session = try await validSession()
		let team = try await currentTeam()
		return try await ALTAppleAPI.sharedAPI.fetchAppIDs(for: team, session: session)
	}

	/// 删除指定 AppID 对应的描述文件以释放免费名额；没有可删的描述文件时返回 false
	@discardableResult
	func deleteProfile(for appID: ALTAppID) async throws -> Bool {
		let session = try await validSession()
		let team = try await currentTeam()
		let deviceType = await Self.currentDeviceType()
		do {
			let profile = try await ALTAppleAPI.sharedAPI.fetchProvisioningProfile(
				for: appID,
				deviceType: deviceType,
				team: team,
				session: session
			)
			try await ALTAppleAPI.sharedAPI.deleteProvisioningProfile(profile, for: team, session: session)
			return true
		} catch {
			let code = Self.altAPIError(from: error)
			if code == .provisioningProfileDoesNotExist
				|| code == .appIDDoesNotExist
				|| code == .invalidProvisioningProfileIdentifier {
				return false
			}
			throw error
		}
	}

	// MARK: - 账号信息刷新（AccountView 用）

	/// 刷新团队 / 证书 / 设备注册状态并发布到界面（失败保持现状）
	func refreshAccountInfo() async {
		guard isLoggedIn else { return }
		do {
			let session = try await validSession()
			let team = try await _refreshTeam(session: session)

			// 证书状态：只看本地持有私钥的（即本模块创建/可复用的）
			if let certificates = try? await _fetchCertificates(team: team, session: session) {
				let owned = certificates.filter {
					_Keychain.load(service: Self.keychainCertKey, account: Self.normalizedSerial($0.serialNumber)) != nil
				}
				let now = Date()
				let active = owned.first(where: { $0.expiryDate > now }) ?? owned.first
				let expiry: Date? = (active != nil && active!.expiryDate > .distantPast) ? active!.expiryDate : nil
				if let expiry {
					UserDefaults.standard.set(expiry, forKey: Self.defaultsCertExpiry)
				}
				await MainActor.run { self.certificateExpiry = expiry }
			}

			// 设备注册状态
			if let udid = try? Self.deviceUDID() {
				let deviceType = await Self.currentDeviceType()
				if let devices = try? await _fetchDevices(team: team, types: [deviceType], session: session) {
					let registered = devices.contains {
						$0.identifier.caseInsensitiveCompare(udid) == .orderedSame
					}
					await MainActor.run { self.deviceIsRegistered = registered }
				}
			}
		} catch {
			NSLog("[AppleID] 刷新账号信息失败：%@", error.localizedDescription)
		}
	}

	// MARK: - 错误描述（界面展示用）

	static func localizedMessage(for error: Error) -> String {
		if let appleIDError = error as? AppleIDError {
			return appleIDError.errorDescription ?? "发生未知错误"
		}
		if let anisetteError = error as? AnisetteServiceError {
			return anisetteError.errorDescription ?? "Anisette 数据获取失败"
		}
		if error is ALTServerError {
			return "苹果服务器返回了无法解析的数据，请稍后重试"
		}

		let nsError = error as NSError
		if nsError.domain == ALTAppleAPIErrorDomain, let code = ALTAppleAPIError(rawValue: nsError.code) {
			switch code {
			case .incorrectCredentials: return "Apple ID 或密码不正确"
			case .requiresTwoFactorAuthentication: return "该账号需要双重认证"
			case .incorrectVerificationCode: return "验证码不正确，请重新输入"
			case .invalidAnisetteData: return "设备验证数据无效，请检查系统时间是否正确后重试"
			case .noTeams: return "该 Apple ID 下没有可用的开发团队"
			case .invalidDeviceID: return "设备 UDID 无效，请到「设备」页重新录入"
			case .deviceAlreadyRegistered: return "设备已注册"
			case .tooManyCertificates: return "证书数量已达上限"
			case .invalidCertificateRequest: return "证书请求无效"
			case .certificateDoesNotExist: return "证书不存在"
			case .invalidAppIDName: return "App 名称包含非法字符"
			case .invalidBundleIdentifier: return "Bundle ID 格式无效"
			case .bundleIdentifierUnavailable: return "该 Bundle ID 已被其他开发者注册，请更换后重试"
			case .appIDDoesNotExist: return "App ID 不存在"
			case .maximumAppIDLimitReached: return "免费账号每 7 天最多注册 10 个 App ID，请稍后再试"
			case .invalidAppGroup: return "App Group 无效"
			case .appGroupDoesNotExist: return "App Group 不存在"
			case .invalidProvisioningProfileIdentifier: return "描述文件标识无效"
			case .provisioningProfileDoesNotExist: return "描述文件不存在"
			case .appSpecificPasswordRequired: return "该账号需要使用 App 专用密码"
			case .authenticationHandshakeFailed: return "与苹果服务器的认证握手失败"
			case .invalidParameters: return "请求参数无效"
			case .unknown: break
			}
		}
		if nsError.domain == NSURLErrorDomain {
			return "网络连接失败，请检查网络后重试"
		}
		return nsError.localizedDescription
	}

	// MARK: - AppID 辅助

	/// 免费开发者 AppID 的 bundleID 只允许字母/数字/横线/点号，其余字符替换为横线
	static func sanitizedBundleIdentifier(_ raw: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
		var scalars = String.UnicodeScalarView()
		for scalar in raw.unicodeScalars {
			if allowed.contains(scalar) {
				scalars.append(scalar)
			} else {
				scalars.append("-")
			}
		}
		var result = String(scalars)
		while result.contains("--") {
			result = result.replacingOccurrences(of: "--", with: "-")
		}
		return result
	}

	private func _ensureAppID(bundleID rawBundleID: String, name: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppID {
		let bundleID = Self.sanitizedBundleIdentifier(rawBundleID)
		let existing = try await ALTAppleAPI.sharedAPI.fetchAppIDs(for: team, session: session)
		if let match = existing.first(where: { $0.bundleIdentifier == bundleID }) {
			return match
		}
		// 冲突（9401 bundleIdentifierUnavailable）等错误直接抛给调用方
		return try await ALTAppleAPI.sharedAPI.addAppID(
			withName: name,
			bundleIdentifier: bundleID,
			team: team,
			session: session
		)
	}

	// MARK: - 私有：通用辅助

	private func _freshAnisette() async throws -> ALTAnisetteData {
		do {
			return try await AnisetteService.shared.fetchAnisetteData()
		} catch {
			throw AppleIDError.anisetteUnavailable
		}
	}

	/// 读取已录入的设备 UDID（用户从电脑端复制后录入，仅存本机）
	static func deviceUDID() throws -> String {
		guard let udid = DeviceIdentity.udid else {
			throw AppleIDError.udidNotConfigured
		}
		return udid
	}


	static func currentDeviceType() async -> ALTDeviceType {
		await MainActor.run {
			UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
		}
	}

	/// 设备名清洗为 ASCII（注册设备 / 证书机器名用）
	static func sanitizedDeviceName() async -> String {
		await MainActor.run {
			let raw = UIDevice.current.name
			let allowed = CharacterSet.alphanumerics
				.union(.whitespaces)
				.union(CharacterSet(charactersIn: "-"))
			var scalars = String.UnicodeScalarView()
			for scalar in raw.unicodeScalars {
				scalars.append(allowed.contains(scalar) ? scalar : " ")
			}
			var cleaned = String(scalars)
				.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
				.trimmingCharacters(in: .whitespaces)
			if cleaned.isEmpty {
				cleaned = UIDevice.current.userInterfaceIdiom == .pad ? "geekIpa iPad" : "geekIpa iPhone"
			}
			return cleaned
		}
	}

	static func normalizedSerial(_ serial: String) -> String {
		let trimmed = serial.uppercased().drop(while: { $0 == "0" })
		return trimmed.isEmpty ? "0" : String(trimmed)
	}

	static func altAPIError(from error: Error) -> ALTAppleAPIError? {
		let nsError = error as NSError
		guard nsError.domain == ALTAppleAPIErrorDomain else { return nil }
		return ALTAppleAPIError(rawValue: nsError.code)
	}

	/// 取指定证书的 p12 密码；没有则生成随机密码并存入钥匙串
	private func _p12Password(for serialKey: String) -> String {
		if let existing = _Keychain.loadString(service: Self.keychainP12Password, account: serialKey) {
			return existing
		}
		let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
		_Keychain.saveString(generated, service: Self.keychainP12Password, account: serialKey)
		return generated
	}

	private func _saveCertIdentity(serialKey: String, expiry: Date) {
		let defaults = UserDefaults.standard
		defaults.set(serialKey, forKey: Self.defaultsCertSerial)
		if expiry > .distantPast {
			defaults.set(expiry, forKey: Self.defaultsCertExpiry)
		}
		Task { @MainActor in
			self.certificateExpiry = expiry > .distantPast ? expiry : nil
		}
	}

	private func _adopt(session: ALTAppleAPISession, account: ALTAccount, email: String) {
		_session = session
		_sessionValidatedAt = Date()
		_account = account

		let defaults = UserDefaults.standard
		defaults.set(email, forKey: Self.defaultsEmail)
		defaults.set(account.name, forKey: Self.defaultsName)

		Task { @MainActor in
			self.isLoggedIn = true
			self.accountEmail = email
			self.accountName = account.name
		}
	}

	@discardableResult
	private func _refreshTeam(session: ALTAppleAPISession) async throws -> ALTTeam {
		guard let account = _account else { throw AppleIDError.notLoggedIn }
		let teams = try await _fetchTeams(account: account, session: session)
		guard let team = teams.first(where: { $0.type == .free }) ?? teams.first else {
			throw AppleIDError.noTeam
		}
		_team = team

		let defaults = UserDefaults.standard
		defaults.set(team.name, forKey: Self.defaultsTeamName)
		defaults.set(team.identifier, forKey: Self.defaultsTeamID)

		await MainActor.run { self.teamName = team.name }
		return team
	}

	// MARK: - 私有：会话持久化

	private func _saveSession(_ session: ALTAppleAPISession, for email: String) {
		let dict: [String: Any] = [
			"dsid": session.dsid,
			"authToken": session.authToken,
			"savedAt": Date().timeIntervalSince1970
		]
		guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
		_Keychain.save(data, service: Self.keychainSession, account: email)
	}

	private func _loadSession(for email: String) -> (dsid: String, authToken: String, savedAt: Date)? {
		guard
			let data = _Keychain.load(service: Self.keychainSession, account: email),
			let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let dsid = dict["dsid"] as? String,
			let authToken = dict["authToken"] as? String
		else { return nil }
		let savedAt = (dict["savedAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
		return (dsid, authToken, savedAt)
	}

	private func _deleteSession(for email: String) {
		_Keychain.delete(service: Self.keychainSession, account: email)
		_session = nil
		_sessionValidatedAt = nil
	}

	// MARK: - 私有：AltSign 回调 API 的 async 包装

	private func _authenticate(
		appleID: String,
		password: String,
		anisetteData: ALTAnisetteData,
		twoFactorCodeProvider: (() async -> String?)?
	) async throws -> (ALTAccount, ALTAppleAPISession) {
		let cancelFlag = _TwoFactorCancelFlag()

		let verificationHandler: ((@escaping (String?) -> Void) -> Void)?
		if let provider = twoFactorCodeProvider {
			verificationHandler = { respond in
				Task {
					if let code = await provider(), !code.isEmpty {
						respond(code)
					} else {
						cancelFlag.cancelled = true
						respond(nil)
					}
				}
			}
		} else {
			verificationHandler = nil
		}

		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(ALTAccount, ALTAppleAPISession), Error>) in
			ALTAppleAPI.sharedAPI.authenticate(
				appleID: appleID,
				password: password,
				anisetteData: anisetteData,
				xcodeVersion: Self.xcodeVersion,
				verificationHandler: verificationHandler,
				completionHandler: { account, session, error in
					if let account, let session {
						continuation.resume(returning: (account, session))
					} else if cancelFlag.cancelled {
						continuation.resume(throwing: AppleIDError.twoFactorCancelled)
					} else {
						continuation.resume(throwing: error ?? AppleIDError.unknown)
					}
				}
			)
		}
	}

	private func _fetchAccount(session: ALTAppleAPISession) async throws -> ALTAccount {
		try await withCheckedThrowingContinuation { continuation in
			ALTAppleAPI.sharedAPI.fetchAccount(session: session) { result in
				continuation.resume(with: result)
			}
		}
	}

	private func _fetchTeams(account: ALTAccount, session: ALTAppleAPISession) async throws -> [ALTTeam] {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ALTTeam], Error>) in
			ALTAppleAPI.sharedAPI.fetchTeams(for: account, session: session) { teams, error in
				if let teams {
					continuation.resume(returning: teams)
				} else {
					continuation.resume(throwing: error ?? AppleIDError.unknown)
				}
			}
		}
	}

	private func _fetchDevices(team: ALTTeam, types: ALTDeviceType, session: ALTAppleAPISession) async throws -> [ALTDevice] {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ALTDevice], Error>) in
			ALTAppleAPI.sharedAPI.fetchDevices(for: team, types: types, session: session) { devices, error in
				if let devices {
					continuation.resume(returning: devices)
				} else {
					continuation.resume(throwing: error ?? AppleIDError.unknown)
				}
			}
		}
	}

	private func _registerDevice(name: String, udid: String, type: ALTDeviceType, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTDevice {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ALTDevice, Error>) in
			ALTAppleAPI.sharedAPI.registerDevice(name: name, identifier: udid, type: type, team: team, session: session) { device, error in
				if let device {
					continuation.resume(returning: device)
				} else {
					continuation.resume(throwing: error ?? AppleIDError.unknown)
				}
			}
		}
	}

	private func _fetchCertificates(team: ALTTeam, session: ALTAppleAPISession) async throws -> [ALTX509Certificate] {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ALTX509Certificate], Error>) in
			ALTAppleAPI.sharedAPI.fetchCertificates(for: team, session: session) { certificates, error in
				if let certificates {
					continuation.resume(returning: certificates)
				} else {
					continuation.resume(throwing: error ?? AppleIDError.unknown)
				}
			}
		}
	}

	private func _addCertificate(machineName: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ALTCertificate, Error>) in
			ALTAppleAPI.sharedAPI.addCertificate(machineName: machineName, to: team, session: session) { certificate, error in
				if let certificate {
					continuation.resume(returning: certificate)
				} else {
					continuation.resume(throwing: error ?? AppleIDError.unknown)
				}
			}
		}
	}

	private func _revokeCertificate(_ certificate: ALTX509Certificate, team: ALTTeam, session: ALTAppleAPISession) async throws -> Bool {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
			ALTAppleAPI.sharedAPI.revoke(certificate, for: team, session: session) { success, error in
				if success {
					continuation.resume(returning: true)
				} else {
					continuation.resume(throwing: error ?? AppleIDError.unknown)
				}
			}
		}
	}
}

// MARK: - AppleIDContracts 协议实现

extension AppleIDManager: AppleIDSessionProviding {}
extension AppleIDManager: ProvisioningRefreshing {}
extension AppleIDManager: AppIDListing {}
