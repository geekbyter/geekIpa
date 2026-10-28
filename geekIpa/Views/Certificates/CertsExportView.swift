//
//  CertsExportView.swift
//  geekIpa
//
//  导出 P12（规格书 §3.4）：弹窗展示密码 → 生成 .p12 文件 → 系统分享面板。
//  说明：现有 Zsign 封装仅提供 p12 密码校验（p12_password_check），没有
//  P12 重加密接口，因此导出的文件保留导入时设置的密码，本页负责展示与复制。
//

import SwiftUI
import UIKit
import NimbleExtensions

struct CertsExportView: View {
	let cert: CertificatePair

	@Environment(\.dismiss) private var dismiss
	@State private var _showPassword = false

	private var _password: String? {
		guard let password = cert.password, !password.isEmpty else { return nil }
		return password
	}

	private var _fileName: String {
		let base = cert.nickname ?? Storage.shared.getProvisionFileDecoded(for: cert)?.Name ?? "certificate"
		let cleaned = base.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
		return cleaned.isEmpty ? "certificate" : cleaned
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					Text("导出的 .p12 文件保留导入时设置的密码，分享后请妥善保管，不要发送给不可信的人。")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}

				Section {
					if let password = _password {
						HStack {
							Text(_showPassword ? password : String(repeating: "•", count: 10))
								.font(.body.monospaced())
								.lineLimit(1)
							Spacer()
							Button {
								_showPassword.toggle()
							} label: {
								Image(systemName: _showPassword ? "eye.slash" : "eye")
							}
							.buttonStyle(.borderless)
							Button {
								UIPasteboard.general.string = password
								GeekToast.show("已复制")
							} label: {
								Image(systemName: "doc.on.doc")
							}
							.buttonStyle(.borderless)
						}
					} else {
						Text("无密码")
							.foregroundStyle(.secondary)
					}
				} header: {
					Text("P12 密码")
				} footer: {
					Text("如需更换密码，请先删除证书后按新密码重新导入。")
				
				}

				Section {
					LabeledContent("文件名", value: "\(_fileName).p12")
				} header: {
					Text("导出文件")
				}

				Section {
					Button {
						_export()
					} label: {
						Text("导出并分享")
							.font(.body.weight(.semibold))
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.tint(.geekPrimary)
					.listRowBackground(Color.clear)
				}
			}
			.navigationTitle("导出 P12")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("取消") { dismiss() }
				}
			}
		}
		.presentationDetents([.medium])
	}

	private func _export() {
		guard let p12URL = Storage.shared.getFile(.certificate, from: cert) else {
			GeekToast.show("导出失败：找不到证书文件", icon: "xmark.circle.fill")
			return
		}

		let destination = FileManager.default.temporaryDirectory
			.appendingPathComponent("\(_fileName).p12")

		do {
			try? FileManager.default.removeItem(at: destination)
			try FileManager.default.copyItem(at: p12URL, to: destination)
		} catch {
			GeekToast.show("导出失败：\(error.localizedDescription)", icon: "xmark.circle.fill")
			return
		}

		dismiss()
		// 等 sheet 关闭后再弹出分享面板（iPad 上由 UIActivityViewController.show 配置 popover）
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
			UIActivityViewController.show(activityItems: [destination])
		}
	}
}
