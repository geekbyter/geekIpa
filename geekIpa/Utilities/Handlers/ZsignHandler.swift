//
//  ZsignHandler.swift
//  geekIpa
//
//  Created by samara on 17.04.2025.
//

import Foundation
import Zsign
import UIKit

final class ZsignHandler {
	var hadError: Error?
	
	private var _appUrl: URL
	private var _options: Options
	private var _certificate: CertificatePair?
	
	init(
		appUrl: URL,
		options: Options = OptionsManager.shared.options,
		cert: CertificatePair? = nil
	) {
		self._appUrl = appUrl
		self._options = options
		self._certificate = cert
	}
	
	func disinject() async throws {
		guard !_options.disInjectionFiles.isEmpty else {
			return
		}
		
		let bundle = Bundle(url: _appUrl)
		let execPath = _appUrl.appendingPathComponent(bundle?.exec ?? "").relativePath
		
		if !Zsign.removeDylibs(appExecutable: execPath, using: _options.disInjectionFiles) {
			throw SigningFileHandlerError.disinjectFailed
		}
	}
	
	func sign() async throws {
		guard let cert = _certificate else {
			throw SigningFileHandlerError.missingCertifcate
		}

		// Zsign 的 completion 是异步回调：必须等它返回后才能移动产物和写入已签名库。
		// 旧实现立即 return，后续 UI 会在真实签名尚未完成时提前显示“完成”。
		let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
			let lock = NSLock()
			var didResume = false
			let resume = { (value: Bool) in
				lock.lock()
				defer { lock.unlock() }
				guard !didResume else { return }
				didResume = true
				continuation.resume(returning: value)
			}

			// 底层签名未回调时，不允许过程页无限停在“签名中”。
			DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
				resume(false)
			}

			Zsign.sign(
				appPath: _appUrl.relativePath,
				provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
				p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
				p12Password: cert.password ?? "",
				entitlementsPath: _options.appEntitlementsFile?.path ?? "",
				removeProvision: !_options.removeProvisioning,
				completion: { result in
					resume(result)
				}
			)
		}

		guard success else {
			throw SigningFileHandlerError.signFailed
		}
	}
	
	func adhocSign() async throws {
		let _ = Zsign.sign(
			appPath: _appUrl.relativePath,
			entitlementsPath: _options.appEntitlementsFile?.path ?? "",
			adhoc: true,
			removeProvision: !_options.removeProvisioning,
			completion: { success in
				if !success {
					self.hadError = SigningFileHandlerError.signFailed
				}
			}
		)
	}
}
