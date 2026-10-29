//
//  SigningProcessView.swift
//  geekIpa
//
//  签名过程页（规格书 §2.4 / §6 取消语义）：
//  · 由签名配置页 push 进入，导航标题「正在签名」，右上「取消」需二次确认
//  · 进度区吸顶：4pt 进度条 + 28pt Semibold 百分比 + 15pt 阶段文案
//  · 日志区固定屏高 55%，独立滚动自动到底，等宽 12pt，级别着色，环形缓冲 2000 行纯内存
//  · 终态区：成功（安装/导出/完成）· 失败（重试/查看完整日志/关闭）· 已取消（关闭）
//  · 取消是真取消：管线包在可取消 Task 中，各阶段间检查 Task.isCancelled
//

import SwiftUI
import CoreData
import NimbleViews
import UIKit

// MARK: - View

struct SigningProcessView: View {

	enum RunState: Equatable {
		case running
		case success
		case failed
		case cancelled
	}

	let app: AppInfoPresentable
	let options: Options
	let certificate: CertificatePair?
	let appIcon: UIImage?
	/// 终态返回时一并关掉配置页（弹回应用页）；未提供时只 dismiss 自己
	var onDismissFlow: (() -> Void)? = nil

	@Environment(\.dismiss) private var _dismiss
	@StateObject private var _logger = SignLogger()

	@State private var _progress: Double = 0
	@State private var _stageText = "准备中"
	@State private var _runState: RunState = .running
	@State private var _errorSummary: String? = nil

	@State private var _task: Task<Void, Never>? = nil
	@State private var _showCancelConfirm = false
	@State private var _logShareItem: _ShareItem? = nil
	@State private var _exportedLogURL: URL? = nil
	@State private var _showFullLog = false
	@State private var _exportApp: Signed? = nil

	// MARK: Fetch（最新已签名产物，用于成功后的 安装/导出）

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .default
	) private var _signedApps: FetchedResults<Signed>

	// MARK: - Body

	var body: some View {
		GeometryReader { proxy in
			VStack(spacing: 0) {
				if _runState == .failed, let summary = _errorSummary {
					// 失败：顶部错误摘要（§2.4）
					HStack(alignment: .top, spacing: 8) {
						Image(systemName: "xmark.octagon.fill")
						Text(summary)
							.font(.footnote)
							.lineLimit(3)
						Spacer()
					}
					.foregroundStyle(Color.geekDanger)
					.padding(10)
					.background(Color.geekDanger.opacity(0.12))
					.padding(.horizontal, 16)
					.padding(.top, 8)
				}

				_progressSection
					.padding(.horizontal, 16)
					.padding(.top, 8)

				_logSection
					.frame(height: proxy.size.height * 0.55)
					.padding(.horizontal, 16)
					.padding(.top, 12)

				Spacer(minLength: 0)
			}
			.frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
		}
		.background(Color.geekPageBackground)
		.navigationTitle("正在签名")
		.navigationBarTitleDisplayMode(.inline)
		.navigationBarBackButtonHidden(true)
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				Button("取消") {
					_showCancelConfirm = true
				}
				.disabled(_runState != .running)
			}
		}
		.alert("签名进行中，确定取消？", isPresented: $_showCancelConfirm) {
			Button("继续签名", role: .cancel) { }
			Button("确定取消", role: .destructive) {
				_cancelSigning()
			}
		}
		// 导出日志：点击时才生成临时 .log，分享面板关闭后立即删除（§2.4）
		.sheet(item: $_logShareItem, onDismiss: {
			// 分享面板已关闭：立即删除临时文件（sheet 关闭时 item 已置 nil，需用独立记录）
			if let url = _exportedLogURL {
				try? FileManager.default.removeItem(at: url)
				_exportedLogURL = nil
			}
		}) { item in
			_ActivityShareSheet(items: [item.url])
		}
		.sheet(isPresented: $_showFullLog) {
			_fullLogSheet
		}
		.sheet(item: $_exportApp) { signed in
			InstallPreviewView(app: signed, isSharing: true)
				.presentationDetents([.height(520)])
				.presentationDragIndicator(.visible)
		}
		// 终态区（§2.4）
		.safeAreaInset(edge: .bottom) {
			_terminalBar
		}
		.onAppear {
			_run()
		}
		.onDisappear {
			// 兜底：页面被异常退出时终止任务
			if _runState == .running {
				_task?.cancel()
			}
		}
	}
}

// MARK: - 进度区（吸顶）

extension SigningProcessView {

	private var _progressBarColor: Color {
		switch _runState {
		case .running: .geekPrimary
		case .success: .geekSuccess
		case .failed: .geekDanger
		case .cancelled: Color(uiColor: .systemGray3)
		}
	}

	@ViewBuilder
	private var _progressSection: some View {
		VStack(spacing: 8) {
			// UIProgressView 风格 4pt 进度条
			GeometryReader { geo in
				ZStack(alignment: .leading) {
					Capsule()
						.fill(Color(uiColor: .systemGray5))
					Capsule()
						.fill(_progressBarColor)
						.frame(width: max(4, geo.size.width * CGFloat(min(max(_progress, 0), 1))))
				}
			}
			.frame(height: 4)
			.animation(.easeInOut(duration: 0.2), value: _progress)

			HStack(alignment: .firstTextBaseline) {
				Text("\(Int((_progress * 100).rounded()))%")
					.font(.system(size: 28, weight: .semibold))
				Spacer()
				Text(_stageText)
					.font(.system(size: 15))
					.foregroundStyle(.secondary)
			}

			// §2.1 对象标注行
			HStack {
				Text("正在处理临时副本 · \(app.name ?? "App").ipa 的副本，原始文件不受影响")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(2)
				Spacer()
			}
		}
	}
}

// MARK: - 日志区（固定屏高 55%，独立滚动）

extension SigningProcessView {

	@ViewBuilder
	private var _logSection: some View {
		VStack(spacing: 0) {
			HStack {
				Text("日志")
					.font(.subheadline.weight(.semibold))
				Spacer()
				Button {
					_exportLog()
				} label: {
					Image(systemName: "square.and.arrow.up")
				}
				.accessibilityLabel("导出日志")
				Button {
					_logger.clear()
				} label: {
					Image(systemName: "trash")
				}
				.accessibilityLabel("清空日志")
			}
			.padding(.horizontal, 12)
			.padding(.vertical, 8)

			Divider()

			ScrollViewReader { reader in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 2) {
						ForEach(_logger.entries) { entry in
							Text("[\(SignLogger.timeString(for: entry.timestamp))] \(entry.message)")
								.font(.system(size: 12, design: .monospaced))
								.foregroundStyle(entry.level.color)
								.frame(maxWidth: .infinity, alignment: .leading)
								.id(entry.id)
						}
					}
					.padding(8)
				}
				.onChange(of: _logger.entries.count) { _ in
					// 自动滚到底
					if let last = _logger.entries.last {
						reader.scrollTo(last.id, anchor: .bottom)
					}
				}
			}
		}
		.background(Color.geekCardBackground)
		.clipShape(RoundedRectangle(cornerRadius: 10))
	}

	private func _exportLog() {
		guard let url = _logger.exportToTempFile() else {
			_logger.warn("日志导出失败：无法写入临时文件")
			return
		}
		// 覆盖前清理上一次未删除的临时文件
		if let old = _exportedLogURL, old != url {
			try? FileManager.default.removeItem(at: old)
		}
		_exportedLogURL = url
		_logShareItem = _ShareItem(url: url)
	}

	@ViewBuilder
	private var _fullLogSheet: some View {
		NavigationStack {
			ScrollView {
				Text(_logger.renderedText())
					.font(.system(size: 12, design: .monospaced))
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding()
			}
			.navigationTitle("完整日志")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button("导出") {
						_exportLog()
					}
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button("关闭") {
						_showFullLog = false
					}
				}
			}
		}
	}
}

// MARK: - 终态区

extension SigningProcessView {

	@ViewBuilder
	private var _terminalBar: some View {
		switch _runState {
		case .running:
			EmptyView()
		case .success:
			_barContainer {
				HStack(spacing: 12) {
					Button("安装") {
						_install()
					}
					.buttonStyle(.bordered)

					Button("导出") {
						_exportApp = _signedApps.first
					}
					.buttonStyle(.bordered)
					.disabled(_signedApps.first == nil)

					// 完成：主操作
					Button {
						_complete()
					} label: {
						Text("完成")
							.font(.body.weight(.semibold))
							.foregroundStyle(.white)
							.frame(maxWidth: .infinity, minHeight: 44)
							.background(Capsule().fill(Color.geekPrimary))
					}
					.buttonStyle(.plain)
				}
			}
		case .failed:
			_barContainer {
				HStack(spacing: 12) {
					Button {
						_retry()
					} label: {
						Text("重试")
							.font(.body.weight(.semibold))
							.foregroundStyle(.white)
							.frame(minWidth: 64, minHeight: 44)
							.padding(.horizontal, 12)
							.background(Capsule().fill(Color.geekPrimary))
					}
					.buttonStyle(.plain)

					Button("查看完整日志") {
						_showFullLog = true
					}
					.buttonStyle(.bordered)

					Spacer()

					Button("关闭") {
						_dismissFlow()
					}
					.foregroundStyle(.secondary)
				}
			}
		case .cancelled:
			_barContainer {
				Button {
					_dismissFlow()
				} label: {
					Text("关闭")
						.font(.body.weight(.semibold))
						.foregroundStyle(.white)
						.frame(maxWidth: .infinity, minHeight: 44)
						.background(Capsule().fill(Color(uiColor: .systemGray)))
				}
				.buttonStyle(.plain)
			}
		}
	}

	@ViewBuilder
	private func _barContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
		content()
			.padding(.horizontal, 16)
			.padding(.top, 8)
			.padding(.bottom, 4)
			.background(.bar)
	}
}

// MARK: - 签名管线对接（可取消 Task + 阶段回调）

extension SigningProcessView {

	private func _run() {
		guard _task == nil else { return }

		let app = self.app
		let options = self.options
		let certificate = self.certificate
		let appIcon = self.appIcon
		let startDate = Date()

		// 主 Actor 上启动：SwiftUI 状态与日志严格在主线程更新。
		// Zsign 自身在后台线程执行，不在此处阻塞 UI。
		_task = Task { @MainActor in
			let handler = SigningHandler(app: app, options: options)
			handler.appCertificate = certificate
			handler.appIcon = appIcon

			// 进度回调（SigningHandler 新增属性，默认 nil，不影响 FR.signPackageFile）
			handler.progressHandler = { progress, stage in
				DispatchQueue.main.async {
					self._progress = progress
					self._stageText = stage
				}
			}
			// 日志回调（级别, 消息）——SignLogger 内部自行切主线程
			handler.stageLogger = { level, message in
				self._logger.log(SignLogger.Level(rawValue: level) ?? .info, message)
			}

			do {
				self._logger.info("任务开始 · \(app.name ?? "应用") · 所有修改只作用于临时副本")

				// 阶段：校验证书（签名前置检查，失败即回调错误）
				self._applyProgress(0.02, "校验证书")
				try Task.checkCancellation()
				if options.signingOption == .default {
					guard let certificate else {
						self._logger.error("未选择证书")
						throw _SigningPrecheckError.missingCertificate
					}
					if let expiration = certificate.expiration, expiration.timeIntervalSinceNow <= 0 {
						self._logger.error("证书已过期，无法用于签名")
						throw _SigningPrecheckError.certificateExpired
					}
					guard
						let certificateURL = Storage.shared.getFile(.certificate, from: certificate),
						let provisionURL = Storage.shared.getFile(.provision, from: certificate)
					else {
						self._logger.error("证书文件或描述文件缺失，请重新导入证书")
						throw SigningFileHandlerError.missingCertifcate
					}
					self._logger.info("证书校验通过：\(certificate.nickname ?? "未命名证书")")
					self._logger.info("证书文件：\(certificateURL.lastPathComponent)；描述文件：\(provisionURL.lastPathComponent)")
				}

				// 阶段：解析 IPA（copy → 生成临时副本）
				try Task.checkCancellation()
				try await handler.copy()
				try Task.checkCancellation()

				// 阶段：应用配置 → 注入 / 移除 → 重签名 → 打包输出
				// （modify 内部串联 move / addToDatabase，进度由回调细分）
				try await handler.modify()
				try Task.checkCancellation()

				// 成功前验收产物：目录与可执行文件必须存在。
				// 避免 Zsign 回调成功但文件移动/打包失败时仍向用户报告“签名完成”。
				guard
					let outputDirectory = Storage.shared.getAppDirectory(for: app),
					FileManager.default.fileExists(atPath: outputDirectory.path),
					let executable = Bundle(url: outputDirectory)?.executableURL,
					FileManager.default.fileExists(atPath: executable.path)
				else {
					self._logger.error("签名产物校验失败：未找到可执行的 .app 包")
					throw SigningFileHandlerError.appNotFound
				}
				self._logger.info("产物校验通过：\(outputDirectory.lastPathComponent)")

				try? await handler.clean()

				let elapsed = String(format: "%.1f", Date().timeIntervalSince(startDate))
				DispatchQueue.main.async {
					self._task = nil
					self._progress = 1.0
					self._stageText = "完成"
					self._logger.success("签名完成，总耗时 \(elapsed) 秒")
					self._runState = .success

					// 照抄旧 SigningView._start 后置行为：
					// post_installAppAfterSigned 为真时 dismiss 并延迟 post 安装通知
					if options.post_installAppAfterSigned {
						GeekToast.show("已生成已签名副本")
						self._dismissFlow()
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
							NotificationCenter.default.post(name: Notification.Name("geekIpa.installApp"), object: nil)
						}
					}
				}
			} catch is CancellationError {
				// 取消：临时副本直接丢弃，原 IPA 无变化（§2.1：无需回滚）
				try? await handler.clean()
				DispatchQueue.main.async {
					self._task = nil
					if self._runState == .running {
						self._logger.warn("[cancelled] 用户取消签名")
						self._runState = .cancelled
						GeekToast.show("已取消签名", icon: "xmark.circle")
					}
				}
			} catch {
				// 失败：临时副本直接丢弃，不落盘失败产物（§2.4）
				try? await handler.clean()
				DispatchQueue.main.async {
					self._task = nil
					self._logger.error("签名失败：\(error.localizedDescription)")
					self._errorSummary = error.localizedDescription
					self._runState = .failed
				}
			}
		}
	}

	private func _applyProgress(_ value: Double, _ stage: String) {
		DispatchQueue.main.async {
			self._progress = value
			self._stageText = stage
		}
	}

	/// 取消（§6：确认后终止任务 → Toast「已取消签名」→ 终态 [cancelled]）
	private func _cancelSigning() {
		_task?.cancel()
		_logger.warn("[cancelled] 用户取消签名")
		_runState = .cancelled
		GeekToast.show("已取消签名", icon: "xmark.circle")
	}

	private func _retry() {
		_logger.clear()
		_progress = 0
		_stageText = "准备中"
		_errorSummary = nil
		_runState = .running
		_task = nil
		_run()
	}

	/// 安装：dismiss 回应用页后 post「geekIpa.installApp」（与旧行为一致，延迟 0.4s）
	private func _install() {
		_dismissFlow()
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
			NotificationCenter.default.post(name: Notification.Name("geekIpa.installApp"), object: nil)
		}
	}

	/// 完成：dismiss 并 Toast「已生成已签名副本」（§2.4）
	private func _complete() {
		_dismissFlow()
		GeekToast.show("已生成已签名副本")
	}

	/// 优先整流退出（配置页 + 本页一起弹回应用页），否则只 dismiss 本页
	private func _dismissFlow() {
		if let onDismissFlow {
			onDismissFlow()
		} else {
			_dismiss()
		}
	}
}

// MARK: - 辅助类型

/// 分享用临时日志文件（sheet(item:) 需要 Identifiable）
private struct _ShareItem: Identifiable {
	let id = UUID()
	let url: URL
}

/// 系统分享面板（导出日志用）
private struct _ActivityShareSheet: UIViewControllerRepresentable {
	let items: [Any]

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: items, applicationActivities: nil)
	}

	func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

/// 签名前置检查错误
private enum _SigningPrecheckError: LocalizedError {
	case missingCertificate
	case certificateExpired

	var errorDescription: String? {
		switch self {
		case .missingCertificate: "未选择证书，请返回签名配置页选择证书"
		case .certificateExpired: "证书已过期，请返回重新选择有效证书"
		}
	}
}
