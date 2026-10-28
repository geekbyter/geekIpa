//
//  CertsImportView.swift
//  geekIpa
//
//  证书导入表单（规格书 §3.3）：UDID / 企业证书走文件导入。
//  复用现有管线：FR.checkPasswordForCertificate 校验密码，
//  FR.handleCertificateFiles → CertificateFileHandler 落库。
//  失败给出具体原因：密码错误 / 证书过期 / 描述文件无法解析 / 与本机 UDID 不匹配。
//

import SwiftUI
import NimbleViews

struct CertsImportView: View {
	/// 导入类型（仅 .udid / .enterprise 会走到本表单）
	let kind: GeekCertKind
	/// 导入成功回调（参数为新证书 uuid，用于列表高亮）
	var onImported: (String?) -> Void

	@Environment(\.dismiss) private var dismiss

	@State private var _p12URL: URL?
	@State private var _provisionURL: URL?
	@State private var _password = ""
	@State private var _nickname = ""

	@State private var _pickingP12 = false
	@State private var _pickingProvision = false
	@State private var _importing = false
	@State private var _errorMessage: String?
	@State private var _udidMismatchAlert = false

	private var _errorPresenting: Binding<Bool> {
		Binding(
			get: { _errorMessage != nil },
			set: { if !$0 { _errorMessage = nil } }
		)
	}

	private var _canImport: Bool {
		_p12URL != nil && _provisionURL != nil && !_importing
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					_fileButton(
						title: _p12URL?.lastPathComponent ?? "选择 .p12 证书文件",
						icon: "doc.badge.plus",
						chosen: _p12URL != nil
					) { _pickingP12 = true }

					_fileButton(
						title: _provisionURL?.lastPathComponent ?? "选择 .mobileprovision 描述文件",
						icon: "doc.badge.plus",
						chosen: _provisionURL != nil
					) { _pickingProvision = true }
				} header: {
					Text("证书文件")
				} footer: {
					Text("两者必须配套：描述文件内嵌的证书需与 P12 文件中的证书一致。")
				
				}

				Section {
					SecureField("P12 密码（无密码可留空）", text: $_password)
						.textContentType(.password)
				} header: {
					Text("密码")
				}

				Section {
					TextField("选填，便于在列表中识别", text: $_nickname)
				} header: {
					Text("昵称")
				}

				Section {
					Button {
						_startImport()
					} label: {
						HStack {
							Spacer()
							if _importing {
								ProgressView()
							} else {
								Text("导入")
									.font(.body.weight(.semibold))
							}
							Spacer()
						}
					}
					.disabled(!_canImport)
					.buttonStyle(.borderedProminent)
					.tint(.geekPrimary)
					.listRowBackground(Color.clear)
				}
			}
			.navigationTitle("导入\(kind.title)")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("取消") { dismiss() }
				}
			}
			.sheet(isPresented: $_pickingP12) {
				FileImporterRepresentableView(
					allowedContentTypes: [.p12],
					onDocumentsPicked: { urls in
						if let url = urls.first { _p12URL = url }
					}
				)
				.ignoresSafeArea()
			}
			.sheet(isPresented: $_pickingProvision) {
				FileImporterRepresentableView(
					allowedContentTypes: [.mobileProvision],
					onDocumentsPicked: { urls in
						if let url = urls.first { _provisionURL = url }
					}
				)
				.ignoresSafeArea()
			}
			.alert("导入失败", isPresented: _errorPresenting) {
				Button("好", role: .cancel) {}
			} message: {
				Text(_errorMessage ?? "")
			}
			.alert("描述文件不包含本机 UDID", isPresented: $_udidMismatchAlert) {
				Button("仍然导入") { _performImport() }
				Button("取消", role: .cancel) {}
			} message: {
				Text("该描述文件的设备列表中没有本机 UDID，用它签名的应用将无法安装到本机。确定继续导入？")
			}
		}
	}

	@ViewBuilder
	private func _fileButton(
		title: String,
		icon: String,
		chosen: Bool,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Label {
				Text(title)
					.foregroundStyle(chosen ? Color.primary : Color.secondary)
					.lineLimit(1)
			} icon: {
				Image(systemName: chosen ? "checkmark.circle.fill" : icon)
					.foregroundStyle(chosen ? Color.geekSuccess : Color.geekPrimary)
			}
		}
	}

	// MARK: - 导入流程

	private func _startImport() {
		guard let p12URL = _p12URL, let provisionURL = _provisionURL else { return }

		// 1. 解析描述文件
		guard let decoded = CertificateReader(provisionURL).decoded else {
			_errorMessage = "描述文件无法解析，请确认选择的是有效的 .mobileprovision 文件。"
			return
		}

		// 2. 过期校验
		if decoded.ExpirationDate <= .now {
			_errorMessage = "证书已过期（有效期至 \(GeekDateFormat.dayString(decoded.ExpirationDate))），请更换证书后重试。"
			return
		}

		// 3. 密码校验
		guard FR.checkPasswordForCertificate(for: p12URL, with: _password, using: provisionURL) else {
			_errorMessage = "密码错误，请检查 P12 密码后重试。"
			return
		}

		// 4. 本机 UDID 匹配校验（非阻断，拿不到本机 UDID 时跳过）
		if decoded.ProvisionsAllDevices != true,
		   let devices = decoded.ProvisionedDevices,
		   !devices.isEmpty,
		   let udid = GeekDeviceIdentity.udid,
		   !devices.contains(udid) {
			_udidMismatchAlert = true
			return
		}

		_performImport()
	}

	private func _performImport() {
		guard let p12URL = _p12URL, let provisionURL = _provisionURL else { return }

		_importing = true
		FR.handleCertificateFiles(
			p12URL: p12URL,
			provisionURL: provisionURL,
			p12Password: _password,
			certificateName: _nickname // 留空则由列表回落到描述文件 Name
		) { error in
			_importing = false
			if let error {
				_errorMessage = "导入失败：\(error.localizedDescription)"
				return
			}
			// 新证书按导入时间倒序排在最前
			let newestUUID = Storage.shared.getAllCertificates().first?.uuid
			dismiss()
			onImported(newestUUID)
		}
	}
}
