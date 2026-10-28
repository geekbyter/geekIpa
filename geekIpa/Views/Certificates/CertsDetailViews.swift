//
//  CertsDetailViews.swift
//  geekIpa
//
//  证书详情页 + 描述文件详情页（规格书 §3.4）。
//  数据源：CertificateReader 解析的 .mobileprovision plist + 内嵌 DER 证书（X509）。
//  任何字段解析失败显示「—」，不崩溃。
//

import SwiftUI
import NimbleExtensions
import UIKit

// MARK: - 证书详情页

struct CertsCertDetailView: View {
	let cert: CertificatePair

	@State private var _decoded: Certificate?
	@State private var _x509: GeekX509Info?

	private var _expiry: GeekCertExpiryState {
		GeekCertExpiryState(expiration: cert.expiration ?? _decoded?.ExpirationDate)
	}

	var body: some View {
		Form {
			Section("证书") {
				_row("Subject", value: _x509?.subject)
				_row("Issuer", value: _x509?.issuer)
				_row("序列号", value: _x509?.serialNumber)
			}

			Section("SHA-1 指纹") {
				if let sha1 = _x509?.sha1Fingerprint {
					HStack {
						Text(sha1)
							.font(.footnote.monospaced())
							.textSelection(.enabled)
						Spacer()
						Button {
							UIPasteboard.general.string = sha1
							GeekToast.show("已复制")
						} label: {
							Image(systemName: "doc.on.doc")
						}
						.buttonStyle(.borderless)
					}
				} else {
					Text("—")
						.foregroundStyle(.secondary)
				}
			}

			Section("有效期") {
				_row("生效日期", value: GeekDateFormat.dayString(_decoded?.CreationDate))
				LabeledContent("到期日期") {
					Text(GeekDateFormat.dayString(cert.expiration ?? _decoded?.ExpirationDate))
						.foregroundStyle(_expiry.color)
				}
				_statusRow()
			}

			Section("绑定设备") {
				if let all = _decoded?.ProvisionsAllDevices, all {
					Text("允许全部设备（不绑定 UDID）")
						.foregroundStyle(.secondary)
				} else if let devices = _decoded?.ProvisionedDevices {
					LabeledContent("设备数量", value: "\(devices.count) 台")
					DisclosureGroup("UDID 列表") {
						ForEach(devices, id: \.self) { udid in
							Button {
								UIPasteboard.general.string = udid
								GeekToast.show("已复制")
							} label: {
								HStack {
									Text(udid)
										.font(.footnote.monospaced())
										.foregroundStyle(.secondary)
									Spacer()
									Image(systemName: "doc.on.doc")
										.font(.footnote)
										.foregroundStyle(.secondary)
								}
							}
							.buttonStyle(.plain)
						}
					}
				} else {
					Text("—")
						.foregroundStyle(.secondary)
				}
			}

			if let entitlements = _decoded?.Entitlements, !entitlements.isEmpty {
				Section("权限能力") {
					ForEach(entitlements.keys.sorted().prefix(5), id: \.self) { key in
						VStack(alignment: .leading, spacing: 2) {
							Text(key)
								.font(.footnote.monospaced())
							Text(_brief(entitlements[key]?.value))
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(1)
						}
					}
					NavigationLink("查看完整权限（\(entitlements.count) 项）") {
						CertificatesInfoEntitlementView(entitlements: entitlements)
					}
				}
			}

			if let directory = Storage.shared.getUuidDirectory(for: cert),
			   let shared = directory.toSharedDocumentsURL() {
				Section {
					Button {
						UIApplication.open(shared)
					} label: {
						Label("在「文件」中打开证书目录", systemImage: "folder")
					}
				}
			}
		}
		.navigationTitle("证书详情")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear {
			_decoded = Storage.shared.getProvisionFileDecoded(for: cert)
			_x509 = GeekX509Info(derData: _decoded?.DeveloperCertificates?.first)
		}
	}

	@ViewBuilder
	private func _statusRow() -> some View {
		let expiry = _expiry
		LabeledContent("状态") {
			HStack(spacing: 6) {
				if expiry.isExpired {
					Text("已过期").foregroundStyle(Color.geekDanger)
				} else if case .expiringSoon(let days) = expiry {
					Text("即将过期 · 剩余 \(days) 天").foregroundStyle(Color.geekWarning)
				} else {
					Text("有效").foregroundStyle(Color.geekSuccess)
				}
				if cert.revoked {
					Text("· 已吊销").foregroundStyle(Color.geekDanger)
				}
			}
		}
	}

	@ViewBuilder
	private func _row(_ title: String, value: String?) -> some View {
		LabeledContent(title) {
			Text(value ?? "—")
				.font(.footnote)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)
		}
	}

	private func _brief(_ value: Any?) -> String {
		guard let value else { return "" }
		if let array = value as? [Any] { return "共 \(array.count) 项" }
		if let dict = value as? [String: Any] { return "共 \(dict.count) 个键" }
		return String(describing: value)
	}
}

// MARK: - 描述文件详情页

struct CertsProfileDetailView: View {
	let cert: CertificatePair

	@State private var _decoded: Certificate?

	var body: some View {
		Form {
			Section("基本信息") {
				_row("名称", value: _decoded?.Name)
				_row("UUID", value: _decoded?.UUID)
				_row("Team ID", value: _decoded?.TeamIdentifier.joined(separator: ", "))
				_row("团队名称", value: _decoded?.TeamName)
				_row("App ID", value: _decoded?.AppIDName)
				_row("标识前缀", value: _decoded?.ApplicationIdentifierPrefix?.joined(separator: ", "))
			}

			Section("设备") {
				if let all = _decoded?.ProvisionsAllDevices, all {
					LabeledContent("设备范围", value: "全部设备（企业分发）")
				} else {
					LabeledContent("设备数量", value: _decoded?.ProvisionedDevices.map { "\($0.count) 台" } ?? "—")
				}
				if let devices = _decoded?.ProvisionedDevices, !devices.isEmpty {
					DisclosureGroup("设备 UDID 列表") {
						ForEach(devices, id: \.self) { udid in
							Text(udid)
								.font(.footnote.monospaced())
								.foregroundStyle(.secondary)
								.textSelection(.enabled)
						}
					}
				}
			}

			Section("时间") {
				_row("创建时间", value: GeekDateFormat.dayString(_decoded?.CreationDate))
				LabeledContent("过期时间") {
					Text(GeekDateFormat.dayString(_decoded?.ExpirationDate))
						.foregroundStyle(GeekCertExpiryState(expiration: _decoded?.ExpirationDate).color)
				}
				_row("有效天数", value: _decoded.map { "\($0.TimeToLive) 天" })
			}

			Section("其他") {
				_row("平台", value: _decoded?.Platform.joined(separator: ", "))
				_row("描述文件版本", value: _decoded.map { "\($0.Version)" })
				if let managed = _decoded?.IsXcodeManaged {
					_row("Xcode 托管", value: managed ? "是" : "否")
				}
				if let ppq = _decoded?.PPQCheck {
					_row("PPQ 检查", value: ppq ? "开启" : "关闭")
				}
			}
		}
		.navigationTitle("描述文件")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear {
			_decoded = Storage.shared.getProvisionFileDecoded(for: cert)
		}
	}

	@ViewBuilder
	private func _row(_ title: String, value: String?) -> some View {
		LabeledContent(title) {
			Text(value ?? "—")
				.font(.footnote)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)
		}
	}
}
