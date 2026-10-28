//
//  AppleIDAccountView.swift
//  geekIpa
//
//  职责：
//  1. AppleIDAccountView —— 已登录账号详情界面：邮箱、姓名、团队、证书状态
//     （有效期/剩余天数）、设备注册状态、「退出登录」按钮（含确认弹窗）。
//  2. AppleIDSignButton —— 「使用 Apple ID 签名」入口按钮，用于嵌入签名页。
//     WIRE: SigningView（本文件不修改 SigningView.swift，由主工程接入）。
//

import SwiftUI

// MARK: - 账号详情

struct AppleIDAccountView: View {
	@ObservedObject private var _manager = AppleIDManager.shared

	@State private var _showLoginSheet = false
	@State private var _showLogoutConfirm = false

	init() {}

	var body: some View {
		Form {
			if _manager.isLoggedIn {
				Section("账号") {
					LabeledContent("邮箱", value: _manager.accountEmail ?? "未知")
					if let name = _manager.accountName, !name.isEmpty {
						LabeledContent("姓名", value: name)
					}
					LabeledContent("团队", value: _manager.teamName ?? "获取中…")
				}

				Section("开发证书") {
					if let expiry = _manager.certificateExpiry {
						LabeledContent("有效期至", value: expiry.formatted(date: .abbreviated, time: .omitted))
						if let days = _manager.certificateRemainingDays {
							LabeledContent("剩余", value: days > 0 ? "\(days) 天" : "已过期")
						}
					} else {
						Text("尚未创建证书，首次使用 Apple ID 签名时将自动创建")
							.font(.footnote)
							.foregroundColor(.secondary)
					}
					LabeledContent("设备注册", value: _manager.deviceIsRegistered ? "已注册" : "未注册")
				}

				Section {
					Button(role: .destructive) {
						_showLogoutConfirm = true
					} label: {
						Text("退出登录")
							.frame(maxWidth: .infinity)
					}
				} footer: {
					Text("退出登录仅删除本机保存的登录凭据，已创建的证书和描述文件不受影响。")
				}
			} else {
				Section {
					Button {
						_showLoginSheet = true
					} label: {
						Text("登录 Apple ID")
							.frame(maxWidth: .infinity)
					}
				} footer: {
					Text("使用 Apple ID 登录后，可申请免费的开发者证书（描述文件 7 天有效）并直接为应用签名。")
				}
			}
		}
		.navigationTitle("Apple ID")
		.sheet(isPresented: $_showLoginSheet) {
			AppleIDLoginView()
		}
		.alert("退出登录", isPresented: $_showLogoutConfirm) {
			Button("取消", role: .cancel) {}
			Button("退出", role: .destructive) {
				_manager.logout()
			}
		} message: {
			Text("将删除本机保存的 Apple ID 凭据。")
		}
		.task {
			await _manager.refreshAccountInfo()
		}
	}
}

// MARK: - 签名入口按钮

/// 「使用 Apple ID 签名」入口按钮。
///
/// 行为：
/// - 未登录：先弹出登录界面，登录成功后自动继续
/// - 已登录：执行 signPipeline（会话 → 团队 → 注册设备 → 证书 → AppID → 描述文件），
///   将产出的 p12 + mobileprovision 通过现有 FR.handleCertificateFiles 导入证书库；
///   若传入了 `app`，还会用导入的证书直接调用现有签名管线 FR.signPackageFile 完成签名
///
/// WIRE: SigningView —— 在 SigningView 的 Form 中插入（例如 `_cert()` Section 内）：
///     AppleIDSignButton(
///         app: app,
///         bundleID: _temporaryOptions.appIdentifier ?? app.identifier ?? "",
///         name: _temporaryOptions.appName ?? app.name ?? "App",
///         options: _temporaryOptions
///     )
/// 注意：免费证书描述文件与 AppID 一一对应，签名时 bundleID 会被固定为
/// AppleIDManager.sanitizedBundleIdentifier(bundleID)，并关闭 ppqProtection 以保持一致。
struct AppleIDSignButton: View {
	/// 待签名应用（传入则导入证书后直接完成签名；不传则仅准备证书与描述文件并导入证书库）
	let app: AppInfoPresentable?
	let bundleID: String
	let appName: String
	/// 签名选项（不传则使用 OptionsManager 全局选项）
	var options: Options?
	/// 完成回调（成功/失败）
	var onFinished: ((Result<Void, Error>) -> Void)?

	@ObservedObject private var _manager = AppleIDManager.shared
	@State private var _showLoginSheet = false
	@State private var _isWorking = false
	@State private var _statusText: String?
	@State private var _errorMessage: String?
	@State private var _successMessage: String?

	private var _errorPresenting: Binding<Bool> {
		Binding(
			get: { _errorMessage != nil },
			set: { if !$0 { _errorMessage = nil } }
		)
	}

	private var _successPresenting: Binding<Bool> {
		Binding(
			get: { _successMessage != nil },
			set: { if !$0 { _successMessage = nil } }
		)
	}

	init(
		app: AppInfoPresentable? = nil,
		bundleID: String,
		name: String,
		options: Options? = nil,
		onFinished: ((Result<Void, Error>) -> Void)? = nil
	) {
		self.app = app
		self.bundleID = bundleID
		self.appName = name
		self.options = options
		self.onFinished = onFinished
	}

	var body: some View {
		Button {
			_start()
		} label: {
			HStack(spacing: 10) {
				Image(systemName: "person.badge.key")
				VStack(alignment: .leading, spacing: 2) {
					Text("使用 Apple ID 签名")
					if let status = _statusText {
						Text(status)
							.font(.footnote)
							.foregroundColor(.secondary)
					}
				}
				Spacer()
				if _isWorking {
					ProgressView()
				}
			}
		}
		.disabled(_isWorking)
		.sheet(isPresented: $_showLoginSheet, onDismiss: {
			// 登录成功后自动继续签名流程
			if _manager.isLoggedIn {
				_run()
			}
		}) {
			AppleIDLoginView()
		}
		.alert("签名失败", isPresented: _errorPresenting) {
			Button("好", role: .cancel) {}
		} message: {
			Text(_errorMessage ?? "")
		}
		.alert("完成", isPresented: _successPresenting) {
			Button("好", role: .cancel) {}
		} message: {
			Text(_successMessage ?? "")
		}
	}

	// MARK: - 流程

	private func _start() {
		if !_manager.isLoggedIn {
			_showLoginSheet = true
			return
		}
		_run()
	}

	private func _run() {
		_isWorking = true
		_errorMessage = nil
		_successMessage = nil
		_statusText = "正在连接苹果服务器…"

		Task {
			do {
				let result = try await _manager.signPipeline(
					appURL: nil,
					bundleID: bundleID,
					name: appName
				)

				await MainActor.run { _statusText = "正在导入证书…" }
				try await _importCertificate(result)

				if let app {
					await MainActor.run { _statusText = "正在签名…" }
					try await _sign(app: app, bundleID: bundleID)
				}

				await MainActor.run {
					_isWorking = false
					_statusText = nil
					if app != nil {
						_successMessage = "签名完成，可在已签名列表中查看。"
					} else {
						_successMessage = "开发证书与描述文件已导入证书库，签名时请选择该证书。"
					}
					onFinished?(.success(()))
				}
			} catch {
				await MainActor.run {
					_isWorking = false
					_statusText = nil
					_errorMessage = AppleIDManager.localizedMessage(for: error)
					onFinished?(.failure(error))
				}
			}
		}
	}

	/// 把 p12 / mobileprovision 写入临时文件并走现有证书导入管线
	private func _importCertificate(
		_ result: (p12Data: Data, p12Password: String, mobileprovisionData: Data)
	) async throws {
		let temporary = FileManager.default.temporaryDirectory
		let p12URL = temporary.appendingPathComponent("geekipa-appleid-\(UUID().uuidString).p12")
		let profileURL = temporary.appendingPathComponent("geekipa-appleid-\(UUID().uuidString).mobileprovision")
		try result.p12Data.write(to: p12URL)
		try result.mobileprovisionData.write(to: profileURL)

		let nickname = "Apple ID（\(_manager.accountEmail ?? "")）"
		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			FR.handleCertificateFiles(
				p12URL: p12URL,
				provisionURL: profileURL,
				p12Password: result.p12Password,
				certificateName: nickname
			) { error in
				try? FileManager.default.removeItem(at: p12URL)
				try? FileManager.default.removeItem(at: profileURL)
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	/// 用刚导入的证书调用现有签名管线
	private func _sign(app: AppInfoPresentable, bundleID: String) async throws {
		// 按昵称精确匹配本账号刚导入的证书（"Apple ID（邮箱）"），避免并发导入时拿错
		let email = _manager.accountEmail ?? ""
		let expectedNickname = "Apple ID（\(email)）"
		let allCerts = Storage.shared.getAllCertificates()
		guard let pair = allCerts.first(where: { $0.nickname == expectedNickname }) ?? allCerts.first else {
			throw AppleIDError.certificateDataMissing
		}

		var signingOptions = options ?? OptionsManager.shared.options
		// 描述文件与最终 bundleID 必须一致：固定为清洗后的 bundleID，并关闭 ppq 后缀
		signingOptions.appIdentifier = AppleIDManager.sanitizedBundleIdentifier(bundleID)
		signingOptions.ppqProtection = false

		return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			FR.signPackageFile(
				app,
				using: signingOptions,
				icon: nil,
				certificate: pair
			) { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					// 与 SigningView 一致的签名后行为
					if signingOptions.post_deleteAppAfterSigned, !app.isSigned {
						Storage.shared.deleteApp(for: app)
					}
					if signingOptions.post_installAppAfterSigned {
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
							NotificationCenter.default.post(
								name: Notification.Name("geekIpa.installApp"),
								object: nil
							)
						}
					}
					continuation.resume()
				}
			}
		}
	}
}
