//
//  SigningConfigView.swift
//  geekIpa
//
//  签名配置页（规格书 §2.1 / §2.3 / §2.3.1 / §6）：
//  · 公共契约：`SigningConfigView(app:)`，由应用页 push 进入
//  · 全部配置只作用于临时副本，原始 IPA 不受影响（顶部小字常驻标注）
//  · 「注入插件」为唯一危险项：danger 描边卡片 + 阻断式确认弹窗 + 开启后吸顶警示条
//  · 底部固定操作栏：取消（次要）/ 开始签名（主色实心胶囊）；注入开启时切换为 danger「注入并签名」
//  · 开始签名无二次确认，直接 push 签名过程页
//

import SwiftUI
import UIKit
import PhotosUI
import CoreData
import UniformTypeIdentifiers
import NimbleViews

// MARK: - View

struct SigningConfigView: View {
	@Environment(\.dismiss) private var _dismiss
	@StateObject private var _optionsManager = OptionsManager.shared

	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _appIcon: UIImage? = nil

	// 注入插件（§2.3.1）
	@State private var _injectionEnabled = false
	@State private var _showInjectionRiskAlert = false
	@State private var _showInjectionPicker = false
	@State private var _showReplaceFilesAlert = false
	@State private var _injectionErrorMessage: String? = nil

	@State private var _navTarget: _NavTarget?

	private enum _NavTarget: Identifiable {
		case certPicker, signing
		var id: Int {
			switch self {
			case .certPicker: return 0
			case .signing: return 1
			}
		}
	}

	// 修改图标（问题 1：从本地相册选择并校验）
	@State private var _iconPickerItem: PhotosPickerItem?
	@State private var _showIconPickerSheet = false
	@State private var _iconErrorMessage: String?
	@State private var _isApplyingIcon = false

	let app: AppInfoPresentable
	/// 完成后整流退出（由应用页注入，用于整栈弹回列表）
	var onFinished: (() -> Void)? = nil

	// MARK: Fetch

	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .default
	) private var _certificates: FetchedResults<CertificatePair>

	init(app: AppInfoPresentable, onFinished: (() -> Void)? = nil) {
		self.app = app
		self.onFinished = onFinished
		__temporaryCertificate = State(initialValue: UserDefaults.standard.integer(forKey: "geekIpa.selectedCert"))
	}

	private func _selectedCert() -> CertificatePair? {
		guard _certificates.indices.contains(_temporaryCertificate) else { return nil }
		return _certificates[_temporaryCertificate]
	}

	// MARK: - 派生状态

	/// Bundle ID 即时校验（§2.3：非法时红字提示）
	private var _isBundleIDValid: Bool {
		let value = (_temporaryOptions.appIdentifier ?? app.identifier ?? "")
			.trimmingCharacters(in: .whitespaces)
		guard !value.isEmpty else { return false }
		let pattern = "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)+$"
		return value.range(of: pattern, options: .regularExpression) != nil
	}

	private var _canStart: Bool {
		guard _selectedCert() != nil else { return false }
		if _injectionEnabled && _temporaryOptions.injectionFiles.isEmpty { return false }
		return true
	}

	private var _injectionTotalSize: Int64 {
		_temporaryOptions.injectionFiles.reduce(0) { partial, url in
			let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
			return partial + (size ?? 0)
		}
	}

	// MARK: - Body

	var body: some View {
		Form {
			_tempCopyNoticeSection
			_basicInfoSection
			_urlSchemeSection
			_deviceSection
			_signingSection
			_advancedSection
		}
		.navigationTitle("签名配置")
		.navigationBarTitleDisplayMode(.inline)
		// §2.3.1 第二层提醒：开启注入后导航栏下吸顶 danger 警示条
		.safeAreaInset(edge: .top) {
			if _injectionEnabled {
				_injectionWarningStrip
			}
		}
		// §2.3 底部固定操作栏
		.safeAreaInset(edge: .bottom) {
			_bottomActionBar
		}
		// 注入插件：阻断式危险确认弹窗（§2.3.1 第一层）
		.alert("注入插件属于危险操作", isPresented: $_showInjectionRiskAlert) {
			Button("取消", role: .cancel) { }
			Button("我已知晓风险，继续开启", role: .destructive) {
				_injectionEnabled = true
			}
		} message: {
			Text("注入的 dylib / deb 会直接修改 IPA 内部的可执行文件与加载命令，可能导致：\n· App 启动即崩溃或功能异常\n· 签名校验失败，App 无法安装或安装后闪退\n· 被系统判定为篡改包，导致无法安装或后续更新失败\n请仅在充分了解后果、且明确知道所注入文件用途时开启。")
		}
		// 更换注入文件前的替换确认（§2.3.1）
		.alert("替换当前已选文件？", isPresented: $_showReplaceFilesAlert) {
			Button("取消", role: .cancel) { }
			Button("替换", role: .destructive) { _showInjectionPicker = true }
		} message: {
			Text("将清空当前已选的 \(_temporaryOptions.injectionFiles.count) 个文件，替换为新选择的文件。")
		}
		// 注入文件解析 / 架构校验失败
		.alert("无法使用该文件", isPresented: _injectionErrorPresenting) {
			Button("好", role: .cancel) { }
		} message: {
			Text(_injectionErrorMessage ?? "")
		}
		.alert("图标不可用", isPresented: _iconErrorPresenting) {
			Button("好", role: .cancel) { }
		} message: {
			Text(_iconErrorMessage ?? "")
		}
		// 注入文件选择器：UIDocumentPicker 过滤 .dylib / .deb（§2.3.1）
		.sheet(isPresented: $_showInjectionPicker) {
			FileImporterRepresentableView(
				allowedContentTypes: [.dylib, .deb],
				allowsMultipleSelection: true,
				onDocumentsPicked: { urls in
					_handlePickedInjectionFiles(urls)
				}
			)
			.ignoresSafeArea()
		}
		// 单个 navigationDestination(item:)：iOS 16 上叠放多个 isPresented 版只有第一个会触发。
		// 注意：item 绑定在返回后不会自动置 nil，必须在 destination 消失时手动复位，
		// 否则返回后再次点击同一入口不会重新导航。
		.navigationDestination(item: $_navTarget) { target in
			Group {
				switch target {
				case .certPicker:
					CertificatesView(selectedCert: $_temporaryCertificate)
				case .signing:
					SigningProcessView(
						app: app,
						options: _temporaryOptions,
						certificate: _selectedCert(),
						appIcon: _appIcon,
						onDismissFlow: { _finishAll() }
					)
				}
			}
			.onDisappear { _navTarget = nil }
		}
		.onAppear {
			// 已有注入文件（高级页加的）时同步开关态
			_injectionEnabled = !_temporaryOptions.injectionFiles.isEmpty

			// 与旧 SigningView 行为对齐：ppq 保护与批量映射
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
	}
}

// MARK: - 分组表单

extension SigningConfigView {

	/// §2.1 临时副本原则的 UI 表达：顶部一行小字常驻标注
	@ViewBuilder
	private var _tempCopyNoticeSection: some View {
		Section {
			Text("正在配置临时副本 · \(app.name ?? "应用") 的副本，原始文件不受影响")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.listRowBackground(Color.clear)
				.listRowSeparator(.hidden)
		}
	}

	@ViewBuilder
	private var _basicInfoSection: some View {
		Section {
			// Bundle ID：默认原值 + 格式正则即时红字
			VStack(alignment: .leading, spacing: 4) {
				HStack {
					Text("Bundle ID")
					Spacer()
					TextField("com.example.app", text: _bundleIDBinding)
					.multilineTextAlignment(.trailing)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.foregroundStyle(_isBundleIDValid ? Color.primary : Color.geekDanger)
				}
				if !_isBundleIDValid {
					Text("Bundle ID 格式不正确，示例：com.example.app")
						.font(.caption)
						.foregroundStyle(Color.geekDanger)
				}
			}

			// App 显示名：默认原值
			HStack {
				Text("App 显示名")
				Spacer()
				TextField(app.name ?? "App", text: _appNameBinding)
				.multilineTextAlignment(.trailing)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			}

			// 最低系统版本：Menu 下拉
			Picker("最低系统版本", selection: $_temporaryOptions.minimumAppRequirement) {
				ForEach(Options.MinimumAppRequirement.allCases, id: \.self) { requirement in
					Text(_minimumRequirementTitle(requirement)).tag(requirement)
				}
			}
		} header: {
			Text("基础信息")
		}
	}

	@ViewBuilder
	private var _urlSchemeSection: some View {
		Section {
			Toggle(isOn: $_temporaryOptions.removeURLScheme) {
				VStack(alignment: .leading, spacing: 2) {
					Text("移除跳转")
					Text("同时清除 URL Scheme 注册")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("跳转处理")
		}
	}

	@ViewBuilder
	private var _deviceSection: some View {
		Section {
			Toggle(isOn: _removeWatchBinding) {
				VStack(alignment: .leading, spacing: 2) {
					Text("移除手表 App")
					Text("移除 Watch/ 目录")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}

			Toggle(isOn: _fileSharingBinding) {
				VStack(alignment: .leading, spacing: 2) {
					Text("开启文件访问")
					Text("允许在文件 App 与 iTunes 中访问应用文档")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		} header: {
			Text("设备适配")
		}
	}

	@ViewBuilder
	private var _signingSection: some View {
		Section {
			Button {
				_navTarget = .certPicker
			} label: {
				HStack(spacing: 8) {
					Text("证书选择")
						.foregroundStyle(.primary)
					Spacer()
					if let cert = _selectedCert() {
						_CertSummaryLabel(cert: cert)
					} else {
						// 未选证书：红色高亮（§2.3）
						Text("请选择证书")
							.font(.body.weight(.medium))
							.foregroundStyle(Color.geekDanger)
					}
					Image(systemName: "chevron.right")
						.font(.footnote.weight(.semibold))
						.foregroundStyle(.tertiary)
				}
			}

			// Apple ID 免费签名：登录 → 注册设备/App ID → 拉描述文件 → 证书写入证书库。
			// 这里只「准备证书」，真正的签名仍走下方的主按钮，避免重复签名。
			AppleIDSignButton(
				app: nil,
				bundleID: _temporaryOptions.appIdentifier ?? app.identifier ?? "",
				name: _temporaryOptions.appName ?? app.name ?? "App",
				options: _temporaryOptions
			)
		} header: {
			Text("签名设置")
		} footer: {
			if let cert = _selectedCert(), cert.revoked {
				Text("当前证书已被吊销，签名可能失败")
					.foregroundStyle(Color.geekWarning)
			} else {
				Text("没有证书时可用 Apple ID 生成免费证书（7 天有效，占 3 个 App ID 名额之一）。")
			}
		}
	}

	/// 高级区：顺序固定为 签名选项 → 修改图标 → 移除插件 → 注入插件，
	/// 危险操作（移除插件 / 注入插件）统一放最后并默认关闭；
	/// 未实现的 Feather 遗留入口以「下个版本」明确标注，避免点了没反应。
	@ViewBuilder
	private var _advancedSection: some View {
		Section {
			DisclosureGroup("高级") {
				// 签名选项
				NavigationLink("签名选项") {
					Form {
						SigningOptionsView(
							options: $_temporaryOptions,
							temporaryOptions: _optionsManager.options
						)
					}
					.navigationTitle("签名选项")
				}

				_iconPickerRow

				ForEach(_unavailableAdvancedItems, id: \.self) { item in
					HStack {
						Text(item)
							.foregroundStyle(.secondary)
						Spacer()
						Text("下个版本")
							.font(.caption)
							.foregroundStyle(.tertiary)
					}
				}

				// 危险操作（统一危险卡片样式，置于最后）
				_removePlugInsCard
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))

				_injectionCard
					.listRowBackground(Color.clear)
					.listRowSeparator(.hidden)
					.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
			}
		} footer: {
			Text("插件注入与移除插件为危险操作，默认关闭；标注「下个版本」的项当前不可用。")
		}
	}

	/// 未开放的高级项（明确告知，避免误以为功能坏了）
	private var _unavailableAdvancedItems: [String] {
		["已有 Dylib 管理", "Frameworks 与 PlugIns", "Entitlements（BETA）"]
	}

	/// 修改图标：相册选择 → 格式/尺寸校验 → 方形裁切并写入签名参数
	@ViewBuilder
	private var _iconPickerRow: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 12) {
				Group {
					if let icon = _appIcon {
						Image(uiImage: icon)
							.resizable()
							.scaledToFill()
					} else {
						Image(systemName: "app.badge")
							.resizable()
							.scaledToFit()
							.padding(6)
							.foregroundStyle(.tertiary)
					}
				}
				.frame(width: 44, height: 44)
				.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

				VStack(alignment: .leading, spacing: 2) {
					Text("修改图标")
					Text(_appIcon == nil ? "未选择，使用原图标" : "已选择新图标")
						.font(.caption)
						.foregroundStyle(.secondary)
				}

				Spacer()

				Button("选择图片") {
					_showIconPickerSheet = true
				}
				.buttonStyle(.borderless)
				.tint(.geekPrimary)
			}

			if _isApplyingIcon {
				ProgressView()
					.controlSize(.small)
			}

			Text("要求：正方形，边长 ≥120px（推荐 1024×1024），PNG / JPEG。")
				.font(.caption2)
				.foregroundStyle(.tertiary)
		}
		.sheet(isPresented: $_showIconPickerSheet) {
			_PhotosPickerSheet(item: $_iconPickerItem)
		}
		.onChange(of: _iconPickerItem) { newItem in
			guard let newItem else { return }
			_loadIcon(from: newItem)
		}
	}

	/// 从相册读取并校验图标
	private func _loadIcon(from item: PhotosPickerItem) {
		_isApplyingIcon = true
		Task {
			defer { DispatchQueue.main.async { _isApplyingIcon = false } }
			guard
				let data = try? await item.loadTransferable(type: Data.self),
				let image = UIImage(data: data)
			else {
				DispatchQueue.main.async {
					_iconErrorMessage = "无法读取这张图片，请选择 PNG 或 JPEG 格式的图片。"
				}
				return
			}
			DispatchQueue.main.async {
				_applyIcon(image)
			}
		}
	}

	/// 校验并应用图标
	private func _applyIcon(_ image: UIImage) {
		let pixelWidth = image.size.width * image.scale
		let pixelHeight = image.size.height * image.scale
		let minSide = min(pixelWidth, pixelHeight)

		guard minSide >= 120 else {
			_iconErrorMessage = "图片尺寸过小（当前 \(Int(pixelWidth))×\(Int(pixelHeight))），边长需 ≥120px，推荐 1024×1024。"
			_iconPickerItem = nil
			return
		}

		let ratio = max(pixelWidth, pixelHeight) / max(minSide, 1)
		guard ratio <= 1.05 else {
			_iconErrorMessage = "请选择正方形图片（当前 \(Int(pixelWidth))×\(Int(pixelHeight))），推荐 1024×1024。"
			_iconPickerItem = nil
			return
		}

		_appIcon = _squareIcon(from: image)
		_iconPickerItem = nil
		GeekToast.show("图标已应用")
	}

	/// 居中裁切为正方形（1024×1024），供签名管线写入 AppIcon
	private func _squareIcon(from image: UIImage) -> UIImage {
		let side = min(image.size.width, image.size.height)
		let origin = CGPoint(
			x: (image.size.width - side) / 2,
			y: (image.size.height - side) / 2
		)
		let cropped: UIImage
		if let cg = image.cgImage?.cropping(to: CGRect(origin: CGPoint(x: origin.x * image.scale, y: origin.y * image.scale),
		                                               size: CGSize(width: side * image.scale, height: side * image.scale))) {
			cropped = UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
		} else {
			cropped = image
		}

		let target = CGSize(width: 1024, height: 1024)
		let renderer = UIGraphicsImageRenderer(size: target)
		return renderer.image { _ in
			cropped.draw(in: CGRect(origin: .zero, size: target))
		}
	}

	/// 图标校验失败的提示绑定
	private var _iconErrorPresenting: Binding<Bool> {
		Binding(get: { _iconErrorMessage != nil }, set: { if !$0 { _iconErrorMessage = nil } })
	}
}

extension SigningConfigView {

	/// 完成后整流退出：优先交给应用页重置导航状态，兜底只弹掉本页
	private func _finishAll() {
		if let onFinished {
			onFinished()
		} else {
			_dismiss()
		}
	}
}

// MARK: - 注入插件 danger 卡片（§2.3.1）
// MARK: - 注入插件 danger 卡片（§2.3.1）

extension SigningConfigView {

	/// 注入错误提示的展示绑定
	private var _injectionErrorPresenting: Binding<Bool> {
		Binding(get: { _injectionErrorMessage != nil }, set: { if !$0 { _injectionErrorMessage = nil } })
	}

	/// Bundle ID 输入绑定
	private var _bundleIDBinding: Binding<String> {
		Binding(
			get: { _temporaryOptions.appIdentifier ?? app.identifier ?? "" },
			set: { _temporaryOptions.appIdentifier = $0 }
		)
	}

	/// App 显示名输入绑定
	private var _appNameBinding: Binding<String> {
		Binding(
			get: { _temporaryOptions.appName ?? app.name ?? "" },
			set: { _temporaryOptions.appName = $0 }
		)
	}

	/// 开关绑定：关切→开 走阻断弹窗；开→关 立即清空已选文件
	private var _injectionToggleBinding: Binding<Bool> {
		Binding(
			get: { _injectionEnabled },
			set: { newValue in
				if newValue {
					_showInjectionRiskAlert = true
				} else {
					_clearInjectionFiles()
					_injectionEnabled = false
				}
			}
		)
	}

	@ViewBuilder
	private var _injectionCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(Color.geekDanger)
				Text("注入插件")
					.font(.body.weight(.semibold))
					.foregroundStyle(Color.geekDanger)
				Spacer()
				Toggle("", isOn: _injectionToggleBinding)
					.labelsHidden()
			}

			if !_injectionEnabled {
				Text("默认关闭 · 注入会修改 IPA 内部可执行文件")
					.font(.footnote)
					.foregroundStyle(.secondary)
			} else {
				if _temporaryOptions.injectionFiles.isEmpty {
					Text("尚未选择注入文件")
						.font(.footnote)
						.foregroundStyle(.secondary)
				} else {
					ForEach(_temporaryOptions.injectionFiles, id: \.absoluteString) { url in
						HStack(spacing: 8) {
							Image(systemName: "doc.fill")
								.foregroundStyle(.secondary)
							VStack(alignment: .leading, spacing: 2) {
								Text(url.lastPathComponent)
									.font(.footnote)
									.lineLimit(1)
								// cell 次行：文件名 + 大小（§2.3.1）
								Text(_fileSizeString(for: url))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
							Spacer()
							Button(role: .destructive) {
								_removeInjectionFile(url)
							} label: {
								Image(systemName: "xmark.circle.fill")
									.foregroundStyle(.secondary)
							}
							.buttonStyle(.plain)
						}
					}
				}

				Button(_temporaryOptions.injectionFiles.isEmpty ? "选择 dylib / deb 文件" : "重新选择文件") {
					if _temporaryOptions.injectionFiles.isEmpty {
						_showInjectionPicker = true
					} else {
						// 更换文件先确认（§2.3.1）
						_showReplaceFilesAlert = true
					}
				}
				.font(.footnote.weight(.medium))
			}
		}
		.padding(12)
		.background(Color.geekDanger.opacity(0.05))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.strokeBorder(Color.geekDanger, lineWidth: 1)
		)
	}

	/// 移除插件：危险卡片样式（与注入插件一致）
	@ViewBuilder
	private var _removePlugInsCard: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 8) {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundStyle(Color.geekDanger)
				Text("移除插件")
					.font(.body.weight(.semibold))
					.foregroundStyle(Color.geekDanger)
				Spacer()
				Toggle("", isOn: _removePlugInsBinding)
					.labelsHidden()
			}

			Text(_removePlugInsBinding.wrappedValue
				 ? "已启用：签名时会删除 PlugIns/ 目录及其扩展"
				 : "默认关闭 · 删除 IPA 内的 PlugIns 目录（可能影响扩展功能）")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.padding(12)
		.background(Color.geekDanger.opacity(0.05))
		.overlay(
			RoundedRectangle(cornerRadius: 10)
				.strokeBorder(Color.geekDanger, lineWidth: 1)
		)
	}

	/// §2.3.1 第二层：开启后吸顶 danger 警示条 + 「关闭注入」快捷按钮
	@ViewBuilder
	private var _injectionWarningStrip: some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill")
			Text("已启用插件注入，签名前请确认所选文件正确")
				.font(.footnote)
			Spacer(minLength: 4)
			Button("关闭注入") {
				_injectionToggleBinding.wrappedValue = false
			}
			.font(.footnote.weight(.semibold))
		}
		.foregroundStyle(Color.geekDanger)
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
		.background(Color.geekDanger.opacity(0.12))
	}
}

// MARK: - 底部固定操作栏（§2.3）

extension SigningConfigView {

	@ViewBuilder
	private var _bottomActionBar: some View {
		VStack(spacing: 8) {
			if _selectedCert() == nil {
				// 未选证书引导，可点击跳证书选择页
				Button {
					_navTarget = .certPicker
				} label: {
					Text("请先选择证书")
						.font(.footnote)
						.foregroundStyle(Color.geekDanger)
				}
			} else if _injectionEnabled {
				if _temporaryOptions.injectionFiles.isEmpty {
					Text("请先选择要注入的 dylib / deb 文件")
						.font(.footnote)
						.foregroundStyle(Color.geekDanger)
				} else {
					// 将注入 X 个文件（总大小）
					Text("将注入 \(_temporaryOptions.injectionFiles.count) 个文件（\(ByteCountFormatter.string(fromByteCount: _injectionTotalSize, countStyle: .file))）")
						.font(.footnote)
						.foregroundStyle(Color.geekDanger)
				}
			}

			HStack(spacing: 16) {
				Button("取消") {
					_dismiss()
				}
				.font(.body)
				.foregroundStyle(.secondary)
				.frame(minHeight: 44)

				Button {
					_navTarget = .signing
				} label: {
					Text(_injectionEnabled ? "注入并签名" : "开始签名")
						.font(.body.weight(.semibold))
						.foregroundStyle(.white)
						.frame(maxWidth: .infinity, minHeight: 44)
						.background(
							Capsule().fill(_capsuleColor)
						)
				}
				.buttonStyle(.plain)
				.disabled(!_canStart)
			}
		}
		.padding(.horizontal, 16)
		.padding(.top, 8)
		.padding(.bottom, 4)
		.background(.bar)
	}

	private var _capsuleColor: Color {
		if !_canStart { return Color(uiColor: .systemGray3) }
		return _injectionEnabled ? .geekDanger : .geekPrimary
	}
}

// MARK: - 开关绑定（映射到 Options 真实字段）

extension SigningConfigView {

	/// 移除插件 → Options.removeFiles 中的 "PlugIns"（移除 PlugIns/ 目录及其扩展）
	private var _removePlugInsBinding: Binding<Bool> {
		Binding(
			get: { _temporaryOptions.removeFiles.contains("PlugIns") },
			set: { on in
				if on {
					if !_temporaryOptions.removeFiles.contains("PlugIns") {
						_temporaryOptions.removeFiles.append("PlugIns")
					}
				} else {
					_temporaryOptions.removeFiles.removeAll { $0 == "PlugIns" }
				}
			}
		)
	}

	/// 移除手表 → Options.removeFiles 中的 "Watch"（移除 Watch/ 目录）
	private var _removeWatchBinding: Binding<Bool> {
		Binding(
			get: { _temporaryOptions.removeFiles.contains("Watch") },
			set: { on in
				if on {
					if !_temporaryOptions.removeFiles.contains("Watch") {
						_temporaryOptions.removeFiles.append("Watch")
					}
				} else {
					_temporaryOptions.removeFiles.removeAll { $0 == "Watch" }
				}
			}
		)
	}

	/// 开启文件访问 → Options.fileSharing + Options.itunesFileSharing
	private var _fileSharingBinding: Binding<Bool> {
		Binding(
			get: { _temporaryOptions.fileSharing && _temporaryOptions.itunesFileSharing },
			set: { on in
				_temporaryOptions.fileSharing = on
				_temporaryOptions.itunesFileSharing = on
			}
		)
	}
}

// MARK: - 注入文件处理

extension SigningConfigView {

	/// 选中文件：先整批校验（解析失败 / 不含 arm64 立即报错并丢弃本次选择），全部通过后才替换旧选择
	private func _handlePickedInjectionFiles(_ urls: [URL]) {
		guard !urls.isEmpty else { return }

		for url in urls {
			if let error = _InjectionFileValidator.validate(url: url) {
				_injectionErrorMessage = "「\(url.lastPathComponent)」\(error)"
				return
			}
		}

		// 校验全部通过：清空旧文件（删除沙盒内副本，不留存）
		_clearInjectionFiles()

		for url in urls {
			FileManager.default.moveAndStore(url, with: "geekIpaTweak") { storedURL in
				_temporaryOptions.injectionFiles.append(storedURL)
			}
		}
	}

	/// 开→关 / 替换：立即清空已选文件（§2.3.1 回退安全：不留内存、不持久化）
	private func _clearInjectionFiles() {
		let files = _temporaryOptions.injectionFiles
		_temporaryOptions.injectionFiles = []
		for url in files {
			FileManager.default.deleteStored(url) { _ in }
		}
	}

	private func _removeInjectionFile(_ url: URL) {
		FileManager.default.deleteStored(url) { removed in
			_temporaryOptions.injectionFiles.removeAll { $0 == removed }
		}
	}

	private func _fileSizeString(for url: URL) -> String {
		guard
			let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
			let size = attributes[.size] as? Int64
		else { return "大小未知" }
		return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
	}

	private func _minimumRequirementTitle(_ requirement: Options.MinimumAppRequirement) -> String {
		switch requirement {
		case .default: "默认（保持原值）"
		default: "iOS \(requirement.rawValue)"
		}
	}
}

// MARK: - 证书摘要标签（证书名 + 剩余天数）

private struct _CertSummaryLabel: View {
	@ObservedObject var cert: CertificatePair
	@State private var _provisionName: String? = nil

	var body: some View {
		VStack(alignment: .trailing, spacing: 2) {
			Text(cert.nickname ?? _provisionName ?? "未命名证书")
				.foregroundStyle(.primary)
			if let info = cert.expiration?.expirationInfo() {
				Text("剩余 \(info.formatted)")
					.font(.caption)
					.foregroundStyle(info.color)
			}
		}
		.onAppear {
			if _provisionName == nil {
				_provisionName = Storage.shared.getProvisionFileDecoded(for: cert)?.Name
			}
		}
	}
}

// MARK: - 注入文件校验（解析失败 / 不含 arm64 → 报错）

/// 纯 Swift 实现的 Mach-O / ar 头部校验，不引入第三方依赖
private enum _InjectionFileValidator {

	/// 返回 nil 表示可用；否则为错误原因（追加在「文件名」之后展示）
	static func validate(url: URL) -> String? {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 8 else {
			return "无法读取或文件已损坏"
		}

		if url.pathExtension.lowercased() == "deb" {
			// .deb 是 ar 归档，校验 ar 魔数即可；其中包含的 dylib 由签名管线在注入时处理
			let magic = data.prefix(8)
			let arMagic: [UInt8] = [0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A] // "!<arch>\n"
			return magic.elementsEqual(arMagic) ? nil : "不是有效的 .deb 软件包"
		}

		// .dylib：必须是包含 arm64 切片的 Mach-O
		return _containsARM64(data) ? nil : "无法解析，或架构不包含 arm64"
	}

	// MARK: Mach-O

	private static let _cpuTypeARM64: UInt32 = 0x0100_000C

	private static let _fatMagic: UInt32 = 0xCAFE_BABE
	private static let _fatMagic64: UInt32 = 0xCAFE_BABF
	private static let _fatCigam: UInt32 = 0xBEBA_FECA
	private static let _mhMagic: UInt32 = 0xFEED_FACE
	private static let _mhMagic64: UInt32 = 0xFEED_FACF
	private static let _mhCigam: UInt32 = 0xCEFA_EDFE
	private static let _mhCigam64: UInt32 = 0xCFFA_EDFE

	private static func _containsARM64(_ data: Data) -> Bool {
		guard let magic = _u32(data, at: 0, bigEndian: true) else { return false }

		switch magic {
		case _fatMagic, _fatMagic64:
			// fat 头为 big-endian：nfat_arch 在偏移 4，fat_arch 自偏移 8 起
			guard let archCount = _u32(data, at: 4, bigEndian: true), archCount > 0, archCount <= 64 else {
				return false
			}
			let entrySize = magic == _fatMagic64 ? 32 : 20
			for index in 0..<Int(archCount) {
				if let cpuType = _u32(data, at: 8 + index * entrySize, bigEndian: true),
				   cpuType == _cpuTypeARM64 {
					return true
				}
			}
			return false

		case _fatCigam:
			// little-endian 的 fat 变体
			guard let archCount = _u32(data, at: 4, bigEndian: false), archCount > 0, archCount <= 64 else {
				return false
			}
			for index in 0..<Int(archCount) {
				if let cpuType = _u32(data, at: 8 + index * 20, bigEndian: false),
				   cpuType == _cpuTypeARM64 {
					return true
				}
			}
			return false

		case _mhMagic, _mhMagic64:
			// 宿主序（设备为小端）
			return _u32(data, at: 4, bigEndian: false) == _cpuTypeARM64

		case _mhCigam, _mhCigam64:
			// 大端 Mach-O
			return _u32(data, at: 4, bigEndian: true) == _cpuTypeARM64

		default:
			return false
		}
	}

	/// 按字节序读 UInt32（避免未对齐 load 的陷阱）
	private static func _u32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
		guard offset >= 0, offset + 4 <= data.count else { return nil }
		let i0 = data.index(data.startIndex, offsetBy: offset)
		let b0 = UInt32(data[i0])
		let b1 = UInt32(data[data.index(after: i0)])
		let b2 = UInt32(data[data.index(i0, offsetBy: 2)])
		let b3 = UInt32(data[data.index(i0, offsetBy: 3)])
		if bigEndian {
			return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
		}
		return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
	}
}

// MARK: - 相册选择器（UIViewControllerRepresentable 包装）
//
// 避免 SwiftUI PhotosPicker 在 Form/DisclosureGroup 里偶发的主线程卡顿：
// 直接用 PHPickerViewController，行为与系统 PhotosPicker 一致。
private struct _PhotosPickerSheet: UIViewControllerRepresentable {
	@Binding var item: PhotosPickerItem?

	func makeCoordinator() -> Coordinator { Coordinator(item: $item) }

	func makeUIViewController(context: Context) -> PHPickerViewController {
		var config = PHPickerConfiguration()
		config.filter = .images
		config.selectionLimit = 1
		let vc = PHPickerViewController(configuration: config)
		vc.delegate = context.coordinator
		return vc
	}

	func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

	final class Coordinator: NSObject, PHPickerViewControllerDelegate {
		let item: Binding<PhotosPickerItem?>
		init(item: Binding<PhotosPickerItem?>) { self.item = item }

		func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
			picker.dismiss(animated: true)
			guard let provider = results.first?.itemProvider else { return }
			item.wrappedValue = PhotosPickerItem(itemProvider: provider)
		}
	}
}
