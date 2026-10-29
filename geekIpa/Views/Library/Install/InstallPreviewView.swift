//
//  InstallPreview.swift
//  geekIpa
//
//  Created by samara on 22.04.2025.
//

import SwiftUI
import NimbleViews
import OSLog
import UIKit

// MARK: - View
struct InstallPreviewView: View {
	@Environment(\.dismiss) var dismiss

	@AppStorage("geekIpa.useShareSheetForArchiving") private var _useShareSheet: Bool = false
	@State private var _isWebviewPresenting = false
	@State private var progressTask: Task<Void, Never>?
	/// 安装失败文案（用 SwiftUI alert 呈现，保证在 sheet 内一定可见）
	@State private var _errorMessage: String?

	/// 安装通道：统一使用本机 HTTP 服务（无需外部文件/证书）
	private var _method: Int { 0 }
	
	var app: AppInfoPresentable
	@StateObject var viewModel: InstallerStatusViewModel
	@StateObject var installer: ServerInstaller
	
	@State var isSharing: Bool
	
	init(app: AppInfoPresentable, isSharing: Bool = false) {
		self.app = app
		self.isSharing = isSharing
		let viewModel = InstallerStatusViewModel(isIdevice: false)
		self._viewModel = StateObject(wrappedValue: viewModel)
		self._installer = StateObject(wrappedValue: ServerInstaller(app: app, viewModel: viewModel))
	}
	
	// MARK: Body
	var body: some View {
		let cornerRadius = {
			if #available(iOS 26.0, *) {
				28.0
			} else {
				10.5
			}
		}()
		
		VStack(spacing: 8) {
			HStack {
				Text("安装")
					.font(.headline)
				Spacer()
				// 显式关闭入口（问题 3：任何状态下都能退出安装面板）
				Button {
					progressTask?.cancel()
					progressTask = nil
					dismiss()
				} label: {
					Image(systemName: "xmark.circle.fill")
						.font(.title3)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.borderless)
				.accessibilityLabel("关闭")
			}
			.padding(.horizontal, 4)
			.padding(.top, 4)

			ZStack {
				InstallProgressView(app: app, viewModel: viewModel)
				_status()
				_button()
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

			// 固定尺寸滚屏日志面板（geekIpa）
			InstallLogView(height: 200)
		}
		.background(Color(UIColor.secondarySystemBackground))
		.cornerRadius(cornerRadius)
		.padding()
		.sheet(isPresented: $_isWebviewPresenting) {
			SafariRepresentableView(url: installer.pageEndpoint).ignoresSafeArea()
		}
		.alert("安装失败", isPresented: _errorPresenting) {
			Button("好", role: .cancel) {}
		} message: {
			Text(_errorMessage ?? "")
		}
		.onReceive(viewModel.$status) { newStatus in
			InstallLogger.shared.info("状态", "安装状态 → \(String(describing: newStatus))")
			if _method == 0 {
				if case .ready = newStatus {
					Task { await _selfCheckThenOpen() }
				}
				
				if case .sendingPayload = newStatus, _isWebviewPresenting {
					_isWebviewPresenting = false
				}
				
				if case .installing = newStatus {
					if progressTask == nil {
						progressTask = startInstallProgressPolling(
							bundleID: app.identifier ?? "",
							viewModel: viewModel
						)
					}
				}
				
				switch newStatus {
				case .completed, .broken(_):
					progressTask?.cancel()
					progressTask = nil
					#if !targetEnvironment(macCatalyst)
					BackgroundAudioManager.shared.stop()
					#endif
				default:
					break
				}
			}
		}
		.onAppear(perform: _install)
		
		#if !targetEnvironment(macCatalyst)
		.onAppear {
			BackgroundAudioManager.shared.start()
		}
		#endif
		
		.onDisappear {
			progressTask?.cancel()
			progressTask = nil
			
			#if !targetEnvironment(macCatalyst)
			BackgroundAudioManager.shared.stop()
			#endif
		}
	}
	
	@ViewBuilder
	private func _status() -> some View {
		Label(viewModel.statusLabel, systemImage: viewModel.statusImage)
			.padding()
			.labelStyle(.titleAndIcon)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
			.animation(.default, value: viewModel.statusImage)
	}
	
	@ViewBuilder
	private func _button() -> some View {
		ZStack {
			if viewModel.isCompleted {
				Button {
					UIApplication.openApp(with: app.identifier ?? "")
				} label: {
					NBButton("Open", systemImage: "", style: .text)
				}
				.padding()
				.compatTransition()
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
		.animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
	}
	
	private func _install() {
		guard isSharing || app.identifier != Bundle.main.bundleIdentifier! || _method == 1 else {
			_errorMessage = .localized("You cannot update ‘%@‘ with itself, please use an alternative tool to update it.", arguments: Bundle.main.name)
			return
		}
				
		// itms 通道依赖设备本地网络地址（en0）：蜂窝网络下取不到，安装必然失败。
		// 蜂窝网络下取不到本地 IP，直接引导用户连接 Wi-Fi。
		if _method == 0 && ServerInstaller.getLocalAddress() == nil {
			_errorMessage = "当前没有可用的 Wi-Fi 网络地址，本地安装服务无法工作。\n\n请任选其一：\n① 连接 Wi-Fi 后重试（也可先开飞行模式再开 Wi-Fi）；\n② 确认该 Wi-Fi 可以正常上网（iOS 安装需要设备自身网络可用）。"
			return
		}

		let logger = InstallLogger.shared
		logger.clear()
		logger.info("准备", "开始安装流程：\(app.name ?? "未知") (\(app.identifier ?? "?"))")
		logger.info("准备", "安装方式: 本机 HTTP 安装服务（需 Wi-Fi）")
		Task.detached {
			do {
				logger.info("打包", "正在归档应用…")
				let handler = await ArchiveHandler(app: app, viewModel: viewModel)
				try await handler.move()
				
				let packageUrl = try await handler.archive()
				logger.success("打包", "归档完成: \(packageUrl.lastPathComponent)")
				
				if await !isSharing {
					if await _method == 0 {
						await MainActor.run {
							installer.packageUrl = packageUrl
							viewModel.status = .ready
						}
						
						if case .installing = await viewModel.status {
							let task = await startInstallProgressPolling(
								bundleID: app.identifier ?? "",
								viewModel: viewModel
							)

							await MainActor.run {
								progressTask = task
							}
						}

					}
				} else {
					let package = try await handler.moveToArchive(packageUrl, shouldOpen: !_useShareSheet)
					
					if await !_useShareSheet {
						await MainActor.run {
							dismiss()
						}
					} else {
						if let package {
							await MainActor.run {
								dismiss()
								UIActivityViewController.show(activityItems: [package])
							}
						}
					}
				}
			} catch {
				await progressTask?.cancel()
				logger.error("安装", "流程失败: \(error.localizedDescription)")

				await MainActor.run {
					// 失败必须显眼提示（问题 3）：标题 + 原始错误 + 排查建议
					_errorMessage = "\(String(describing: error))\n\n可尝试：①确认已连接 Wi-Fi；②到「设置」查看诊断日志中的具体失败步骤。"
					viewModel.status = .broken(error)
				}
			}
		}
	}
	
	private func startInstallProgressPolling(
		bundleID: String,
		viewModel: InstallerStatusViewModel
	) -> Task<Void, Never> {

		Task.detached(priority: .background) {
			var hasStarted = false

			while !Task.isCancelled {
				let rawProgress = await UIApplication.installProgress(for: bundleID) ?? 0.0

				if rawProgress > 0 {
					hasStarted = true
				}

				let progress = await hasStarted
					? _normalizeInstallProgress(rawProgress)
					: 0.0

				Logger.misc.info("Install progress for \(bundleID): \(progress)")

				await MainActor.run {
					viewModel.installProgress = progress
				}

				if hasStarted && rawProgress == 0 {
					await MainActor.run {
						viewModel.installProgress = 1.0
						viewModel.status = .completed(.success(()))
					}
					break
				}

				// 500ms 即可反馈安装进度；原 1ms 轮询会持续占用 CPU，安装时像卡死。
				try? await Task.sleep(nanoseconds: 500_000_000)
			}
		}
	}

	private func _normalizeInstallProgress(_ rawProgress: Double) -> Double {
		min(1.0, max(0.0, (rawProgress - 0.6) / 0.3))
	}
}


// MARK: - geekIpa: 自检与看门狗
extension InstallPreviewView {
	/// 先自检服务器链路，再打开 itms 链接；之后启动看门狗盯 iOS 是否来取清单
	private func _selfCheckThenOpen() async {
		let logger = InstallLogger.shared
		let check = await installer.selfCheck()
		if !check.ok {
			logger.error("自检", "链路自检未通过：\(check.detail)。仍可尝试继续，但大概率失败")
			logger.warning("自检", "建议：确认已连接 Wi-Fi，并查看诊断日志中的失败步骤")
		}
		await MainActor.run {
			logger.info("安装", "打开 itms-services 链接，等待系统弹出安装确认…")
			if let link = URL(string: installer.iTunesLink) {
				UIApplication.shared.open(link)
			} else {
				logger.error("安装", "安装链接无效，无法打开系统安装确认")
			}
			_startManifestWatchdog()
		}
	}

	/// 安装错误提示绑定
	private var _errorPresenting: Binding<Bool> {
		Binding(get: { _errorMessage != nil }, set: { if !$0 { _errorMessage = nil } })
	}

	/// 12 秒内 iOS 没来取清单 → 报错（不再静默卡死）
	private func _startManifestWatchdog() {
		let logger = InstallLogger.shared
		Task { [weak viewModel] in
			try? await Task.sleep(nanoseconds: 12_000_000_000)
			guard !Task.isCancelled else { return }
			guard let viewModel else { return }
			let status = await MainActor.run { viewModel.status }
			if case .ready = status {
				logger.error("看门狗", "12 秒内 iOS 没有来取安装清单——安装确认弹窗可能被系统拒绝")
				logger.error("看门狗", "常见原因：①未连接 Wi-Fi ②未允许「本地网络」权限 ③签名或描述文件不匹配")
				logger.warning("看门狗", "排查顺序：确认 Wi-Fi 已连接 → 设置→隐私与安全性→本地网络 允许本 App → 重试安装")
			}
		}
	}
}
