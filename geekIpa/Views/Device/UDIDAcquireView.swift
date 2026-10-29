//
//  UDIDAcquireView.swift
//  geekIpa
//
//  设备页「获取 UDID」面板：
//  主路径 = 描述文件自动获取（Safari 安装 → 系统回传 → 自动填入）
//  备用路径 = 手动填写
//

import SwiftUI
import UIKit
import NimbleViews

struct UDIDAcquireView: View {

	@Environment(\.dismiss) private var _dismiss
	@ObservedObject private var _service = UDIDProfileService.shared

	@State private var _isStarting = false
	@State private var _errorMessage: String?
	@State private var _showManualEntry = false
	@State private var _manualInput = ""
	@State private var _showProfile = false

	var body: some View {
		NavigationStack {
			Form {
				Section {
					if let udid = DeviceIdentity.udid {
						LabeledContent("当前 UDID") {
							Text(udid)
								.font(.caption.monospaced())
								.multilineTextAlignment(.trailing)
						}
						Button("复制 UDID") {
							UIPasteboard.general.string = udid
							GeekToast.show("已复制")
						}
					} else {
						Text("尚未获取 UDID").foregroundStyle(Color.geekWarning)
					}
				} footer: {
					Text("UDID 只保存在本机，仅用于向 Apple 注册设备。")
				}

				Section {
					Button {
						_startProfileFlow()
					} label: {
						HStack {
							Label("通过描述文件自动获取", systemImage: "safari")
							Spacer()
							if _isStarting { ProgressView().controlSize(.small) }
						}
					}
					.disabled(_isStarting)
				} header: {
					Text("一键获取")
				} footer: {
					Text("在应用内下载描述文件 → 到「设置 → 已下载描述文件」安装 → 系统回传设备信息，自动填入 UDID。返回本页面后点「继续获取」可查看结果。")
				}

				if _service.receivedSerial != nil || _service.receivedUDID != nil {
					Section {
						if let udid = _service.receivedUDID { LabeledContent("UDID", value: udid) }
						if let serial = _service.receivedSerial { LabeledContent("序列号", value: serial) }
						if let product = _service.receivedProduct { LabeledContent("型号", value: product) }
						if let version = _service.receivedVersion { LabeledContent("系统", value: version) }
					} header: {
						Text("已收到设备信息")
					} footer: {
						if _service.lastCallbackHadNoUDID {
							Text("本次回传未解析到 UDID，请查看「诊断日志」中的 UDID 记录；也可展开下方「手动填写」。")
								.foregroundStyle(Color.geekWarning)
						} else {
							Text("UDID 已保存，可以直接返回并开始签名。")
								.foregroundStyle(Color.geekSuccess)
						}
					}
				}

				Section {
					DisclosureGroup("手动填写", isExpanded: $_showManualEntry) {
						TextField("粘贴 UDID（40 位或 25 位）", text: $_manualInput)
							.textInputAutocapitalization(.never)
							.autocorrectionDisabled()
							.font(.body.monospaced())
						Button("保存手动填写的 UDID") {
							if DeviceIdentity.save(_manualInput) {
								GeekToast.show("UDID 已保存")
								_dismiss()
							} else {
								_errorMessage = "UDID 格式不正确：应为 40 位十六进制，或 iPhone X 及之后的 25 位格式。"
							}
						}
						.disabled(_manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
						Text(DeviceIdentity.guidance)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}

				if DeviceIdentity.hasUDID {
					Section {
						Button("清除已保存的 UDID", role: .destructive) {
							DeviceIdentity.clear()
							GeekToast.show("已清除")
							_dismiss()
						}
					}
				}
			}
			.navigationTitle("获取设备 UDID")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("关闭") {
						UDIDProfileService.shared.stop()
						_dismiss()
					}
				}
			}
			.alert("提示", isPresented: Binding(
				get: { _errorMessage != nil },
				set: { if !$0 { _errorMessage = nil } }
			)) {
				Button("好", role: .cancel) {}
			} message: {
				Text(_errorMessage ?? "")
			}
			.onChange(of: _service.receivedUDID) { newValue in
				if newValue != nil { GeekToast.show("UDID 已自动填入") }
			}
			.fullScreenCover(isPresented: $_showProfile) {
				NavigationStack {
					SafariRepresentableView(url: URL(string: "http://127.0.0.1:\(UDIDProfileService.shared.port)/udid.mobileconfig")!)
						.ignoresSafeArea()
						.navigationTitle("下载描述文件")
						.navigationBarTitleDisplayMode(.inline)
						.toolbar {
							ToolbarItem(placement: .cancellationAction) {
								Button("关闭") { _showProfile = false }
							}
						}
				}
			}
			.onDisappear {
				UDIDProfileService.shared.stop()
			}
		}
	}

	private func _startProfileFlow() {
		_isStarting = true
		Task {
			do {
				_ = try await UDIDProfileService.shared.start()
				// 先申请后台时间，再跳 Safari：否则 App 一进后台监听器就被挂起，
				// Safari 请求 127.0.0.1 会连接被拒
				UDIDProfileService.shared.beginBackgroundTask()
				await MainActor.run { _isStarting = false }
				if let profileURL = URL(string: "http://127.0.0.1:\(UDIDProfileService.shared.port)/udid.mobileconfig") {
					// 应用内 Safari：不能跳系统 Safari，否则 App 进入后台，监听器挂起，
					// 127.0.0.1 下载与回传都无法访问。
					await MainActor.run { _showProfile = true }
				}
			} catch {
				await MainActor.run {
					_isStarting = false
					_errorMessage = "无法启动本机服务：\(error.localizedDescription)"
				}
			}
		}
	}
}
