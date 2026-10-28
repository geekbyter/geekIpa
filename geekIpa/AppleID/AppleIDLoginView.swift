//
//  AppleIDLoginView.swift
//  geekIpa
//
//  职责：Apple ID 登录界面（SwiftUI，全简体中文）。
//  - 邮箱 + 密码输入、登录按钮、进度指示、错误展示
//  - 「记住凭据」开关（勾选后密码存入本机钥匙串，用于会话过期后的静默重登）
//  - 双重认证弹窗：AltSign 的 verificationHandler 触发时，通过 async 提供者挂起登录流程，
//    弹出 alert 让用户输入 6 位验证码，取消则以「已取消双重认证」结束
//  - 风险提示文案（凭据只发给苹果服务器）
//  - 登录成功后回调 onSuccess 并自动 dismiss
//

import SwiftUI

struct AppleIDLoginView: View {
	/// 登录成功回调（在 dismiss 之前调用）
	var onSuccess: (() -> Void)?

	@Environment(\.dismiss) private var _dismiss
	@ObservedObject private var _manager = AppleIDManager.shared

	@State private var _email = ""
	@State private var _password = ""
	@State private var _rememberCredentials = true
	@State private var _isWorking = false
	@State private var _errorMessage: String?

	// 双重认证弹窗状态
	@State private var _showTwoFactorAlert = false
	@State private var _twoFactorCode = ""
	@State private var _twoFactorContinuation: CheckedContinuation<String?, Never>?

	private var _errorPresenting: Binding<Bool> {
		Binding(
			get: { _errorMessage != nil },
			set: { if !$0 { _errorMessage = nil } }
		)
	}

	init(onSuccess: (() -> Void)? = nil) {
		self.onSuccess = onSuccess
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("Apple ID（邮箱）", text: $_email)
						.keyboardType(.emailAddress)
						.textContentType(.username)
						.autocapitalization(.none)
						.disableAutocorrection(true)
					SecureField("密码", text: $_password)
						.textContentType(.password)
					Toggle("记住凭据（存入本机钥匙串）", isOn: $_rememberCredentials)
				}

				Section {
					Button {
						_login()
					} label: {
						HStack(spacing: 8) {
							if _isWorking {
								ProgressView()
							}
							Text(_isWorking ? "正在登录…" : "登录")
						}
						.frame(maxWidth: .infinity)
					}
					.disabled(_isWorking || _email.isEmpty || _password.isEmpty)
				}

				Section {
					Text("你的 Apple ID 和密码仅通过加密连接发送至苹果官方服务器（gsa.apple.com / developerservices2.apple.com），用于申请免费的开发者证书（有效期 7 天的描述文件）。本应用不会将凭据上传至任何第三方服务器。")
						.font(.footnote)
						.foregroundColor(.secondary)
				}
			}
			.navigationTitle("Apple ID 登录")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("取消") { _dismiss() }
						.disabled(_isWorking)
				}
			}
			.interactiveDismissDisabled(_isWorking)
			.alert("登录失败", isPresented: _errorPresenting) {
				Button("好", role: .cancel) {}
			} message: {
				Text(_errorMessage ?? "")
			}
			.alert("双重认证", isPresented: $_showTwoFactorAlert) {
				TextField("6 位验证码", text: $_twoFactorCode)
					.keyboardType(.numberPad)
				Button("取消", role: .cancel) {
					_resumeTwoFactor(with: nil)
				}
				Button("验证") {
					_resumeTwoFactor(with: _twoFactorCode)
				}
				.disabled(_twoFactorCode.count != 6)
			} message: {
				Text("验证码已发送至你的受信任设备，请输入 6 位验证码。")
			}
			.onChange(of: _twoFactorCode) { newValue in
				let filtered = String(newValue.filter(\.isNumber).prefix(6))
				if filtered != newValue {
					_twoFactorCode = filtered
				}
			}
		}
	}

	// MARK: - 登录流程

	private func _login() {
		_errorMessage = nil
		_isWorking = true
		let email = _email
		let password = _password
		let remember = _rememberCredentials

		Task {
			do {
				try await _manager.login(
					appleID: email,
					password: password,
					rememberCredentials: remember,
					twoFactorCodeProvider: { await _requestTwoFactorCode() }
				)
				await MainActor.run {
					_isWorking = false
					onSuccess?()
					_dismiss()
				}
			} catch {
				await MainActor.run {
					_isWorking = false
					_errorMessage = AppleIDManager.localizedMessage(for: error)
				}
			}
		}
	}

	// MARK: - 双重认证

	/// 挂起等待用户在弹窗中输入验证码（返回 nil 表示用户取消）
	private func _requestTwoFactorCode() async -> String? {
		await withCheckedContinuation { continuation in
			// @State 必须主线程写入（continuation body 可能跑在 URLSession 回调线程）
			DispatchQueue.main.async {
				self._twoFactorCode = ""
				self._twoFactorContinuation = continuation
				self._showTwoFactorAlert = true
			}
		}
	}

	private func _resumeTwoFactor(with code: String?) {
		_twoFactorContinuation?.resume(returning: code)
		_twoFactorContinuation = nil
	}
}
