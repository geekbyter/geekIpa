//
//  AppsView.swift
//  geekIpa
//
//  应用页容器（规格书 §1.2 / §2）：
//  顶部 UISegmentedControl 风格两段（已导入 / 已签名）+
//  导航栏右侧常驻实心胶囊「导入 IPA」（文件导入 / URL 导入）。
//  由 VariedTabbarView 包进 NavigationStack 使用。
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers
import NimbleViews

struct AppsView: View {
	/// 顶部三个分段（规格书 §1.2）
	enum Banner: Int, CaseIterable, Hashable {
		case imported
		case signed
		
		var title: String {
			switch self {
			case .imported:  return "已导入"
			case .signed:    return "已签名"
			}
		}
		
		/// 导航大标题随分段切换（规格书 §1.2）
		var navigationTitle: String {
			switch self {
			case .imported:  return "已导入 IPA"
			case .signed:    return "已签名 IPA"
			}
		}
	}
	
	@State private var _banner: Banner = .imported
	@State private var _editMode: EditMode = .inactive
	
	@StateObject private var _downloadManager = DownloadManager.shared
	
	/// 安装 / 导出共用弹窗状态（InstallPreviewView，与旧 LibraryView 同一通路）
	@State private var _installAppPresenting: AnyApp?
	
	// 导入相关状态
	@State private var _isImportMenuPresenting = false
	@State private var _isFileImporterPresenting = false
	@State private var _isURLAlertPresenting = false
	@State private var _importURLString = ""
	
	/// 「geekIpa.installApp」通知需要取最新一条已签名记录（沿用旧 LibraryView 逻辑）
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
	) private var _signedApps: FetchedResults<Signed>
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 0) {
			_segmentedControl()
			_bannerContent()
		}
		.background(Color.geekPageBackground.ignoresSafeArea())
		.navigationTitle(_banner.navigationTitle)
		.navigationBarTitleDisplayMode(.large)
		.toolbar { _toolbarContent() }
		.confirmationDialog(
			"导入 IPA",
			isPresented: $_isImportMenuPresenting,
			titleVisibility: .visible
		) {
			Button("文件导入", systemImage: "folder") {
				_isFileImporterPresenting = true
			}
			Button("URL 导入", systemImage: "link") {
				_isURLAlertPresenting = true
			}
			Button("取消", role: .cancel) {}
		} message: {
			Text("从本机文件或网络直链导入未签名的 IPA 包")
		}
		.sheet(isPresented: $_isFileImporterPresenting) {
			_fileImporter()
		}
		.alert("从 URL 导入", isPresented: $_isURLAlertPresenting) {
			TextField("https://example.com/app.ipa", text: $_importURLString)
				.textInputAutocapitalization(.never)
				.keyboardType(.URL)
				.autocorrectionDisabled()
			Button("取消", role: .cancel) {
				_importURLString = ""
			}
			Button("导入") {
				_startURLImport()
			}
		} message: {
			Text("输入 IPA 文件的 http(s) 直链地址")
		}
		.sheet(item: $_installAppPresenting) { app in
			InstallPreviewView(app: app.base, isSharing: app.archive)
				.presentationDetents([.height(520)])
				.presentationDragIndicator(.visible)
		}
		.onReceive(NotificationCenter.default.publisher(for: Notification.Name("geekIpa.installApp"))) { _ in
			// 签名完成 / 续签完成会发该通知：对最新签名 App 弹安装面板（沿用旧 LibraryView 逻辑）
			if let latest = _signedApps.first {
				_installAppPresenting = AnyApp(base: latest)
			}
		}
		.onChange(of: _banner) { _ in
			// 切换分段时退出多选，避免多选状态串到其它列表
			_editMode = .inactive
		}
	}
}

// MARK: - Extension: 子视图
extension AppsView {
	/// 顶部三段分段控件（整宽，左右 16pt，规格书 §1.2）
	@ViewBuilder
	private func _segmentedControl() -> some View {
		Picker("应用列表", selection: $_banner) {
			ForEach(Banner.allCases, id: \.self) { banner in
				Text(banner.title).tag(banner)
			}
		}
		.pickerStyle(.segmented)
		.padding(.horizontal, 16)
		.padding(.vertical, 8)
	}
	
	/// 两个列表共存于 ZStack：切换只改透明度/位移，各列表滚动位置与状态全部保留（规格书 §1.1/§1.2）
	@ViewBuilder
	private func _bannerContent() -> some View {
		ZStack {
			AppsImportedListView(
				installAppPresenting: $_installAppPresenting,
				editMode: $_editMode,
				onImport: { _isImportMenuPresenting = true }
			)
			.opacity(_banner == .imported ? 1 : 0)
			.offset(y: _banner == .imported ? 0 : 6)
			.allowsHitTesting(_banner == .imported)
			.accessibilityHidden(_banner != .imported)
			
			AppsSignedListView(
				installAppPresenting: $_installAppPresenting
			)
			.opacity(_banner == .signed ? 1 : 0)
			.offset(y: _banner == .signed ? 0 : 6)
			.allowsHitTesting(_banner == .signed)
			.accessibilityHidden(_banner != .signed)
			
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		// 切换动效：淡入淡出 + 轻微位移，150–200ms（规格书 §1.2）
		.animation(.easeInOut(duration: 0.18), value: _banner)
	}
	
	@ToolbarContentBuilder
	private func _toolbarContent() -> some ToolbarContent {
		ToolbarItem(placement: .navigationBarLeading) {
			if _banner == .imported {
				Button(_editMode.isEditing ? "取消" : "选择") {
					withAnimation {
						_editMode = _editMode.isEditing ? .inactive : .active
					}
				}
			}
		}
		ToolbarItem(placement: .navigationBarTrailing) {
			// 多选编辑态时右侧让位给「删除 / 导出」（由 AppsImportedListView 的 toolbar 提供）
			if !_editMode.isEditing {
				_importCapsuleButton()
			}
		}
	}
	
	/// 常驻主操作「导入 IPA」：实心胶囊，点击区 ≥44pt（规格书 §1.2）
	@ViewBuilder
	private func _importCapsuleButton() -> some View {
		Button {
			_isImportMenuPresenting = true
		} label: {
			Label("导入 IPA", systemImage: "square.and.arrow.down")
				.font(.subheadline.weight(.semibold))
				.foregroundStyle(.white)
				.padding(.horizontal, 12)
				.padding(.vertical, 7)
				.background(Capsule().fill(Color.geekPrimary))
		}
		.frame(minWidth: 44, minHeight: 44)
		.contentShape(Rectangle())
		.accessibilityLabel("导入 IPA")
	}
}

// MARK: - Extension: 导入逻辑（复用旧 LibraryView 通路）
extension AppsView {
	@ViewBuilder
	private func _fileImporter() -> some View {
		FileImporterRepresentableView(
			allowedContentTypes: [.ipa, .tipa],
			allowsMultipleSelection: true,
			onDocumentsPicked: { urls in
				guard !urls.isEmpty else { return }
				for url in urls {
					let id = "geekIpaManualDownload_\(UUID().uuidString)"
					let dl = _downloadManager.startArchive(from: url, id: id)
					try? _downloadManager.handlePachageFile(url: url, dl: dl)
				}
				GeekToast.show("已开始导入 \(urls.count) 个文件")
			}
		)
		.ignoresSafeArea()
	}
	
	private func _startURLImport() {
		let string = _importURLString.trimmingCharacters(in: .whitespacesAndNewlines)
		_importURLString = ""
		
		guard
			let url = URL(string: string),
			let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https"
		else {
			GeekToast.show("链接格式不正确，请输入 http(s) 直链", icon: "xmark.circle.fill")
			return
		}
		
		_ = _downloadManager.startDownload(from: url, id: "geekIpaManualDownload_\(UUID().uuidString)")
		GeekToast.show("已开始下载")
	}
}
