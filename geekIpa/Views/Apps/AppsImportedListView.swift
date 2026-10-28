//
//  AppsImportedListView.swift
//  geekIpa
//
//  已导入列表（规格书 §2.1 / §2.2）：
//  原始 IPA 只读展示（图标 60×60 圆角 12 + 名称版本 + BundleID·大小·导入时间 +「未签名」标签），
//  点击弹操作菜单（签名 IPA / 查看描述 / 导出 / 删除），长按或「选择」进入多选批量删除/导出。
//

import SwiftUI
import CoreData
import IDeviceSwift
import NimbleExtensions
import UIKit

struct AppsImportedListView: View {
	/// 安装 / 导出弹窗由 AppsView 统一承载
	@Binding var installAppPresenting: AnyApp?
	/// 多选编辑态由 AppsView 持有（导航栏「选择 / 取消」按钮驱动）
	@Binding var editMode: EditMode
	/// 空状态主按钮：弹出导入选择
	var onImport: () -> Void
	
	@State private var _selection: Set<String> = []
	@State private var _actionApp: Imported?       // 操作弹窗对象
	@State private var _deleteApp: Imported?       // 删除二次确认对象
	@State private var _signingApp: Imported?      // push 签名配置页对象
	@State private var _infoApp: Imported?         // push 描述页对象
	@State private var _isSigningActive = false
	@State private var _isInfoActive = false
	@State private var _isBatchDeleteConfirming = false
	@State private var _isBatchExporting = false
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .default
	) private var _importedApps: FetchedResults<Imported>
	
	private var _isEditing: Bool { editMode.isEditing }
	
	// MARK: Body
	var body: some View {
		List {
			ForEach(_importedApps, id: \.uuid) { app in
				_row(for: app)
			}
		}
		.listStyle(.insetGrouped)
		.overlay {
			if _importedApps.isEmpty {
				GeekEmptyStateView(
					icon: "square.and.arrow.down",
					title: "暂无 IPA，点击导入",
					message: "支持从文件或 URL 导入未签名的 IPA 包",
					buttonTitle: "导入 IPA",
					action: onImport
				)
			}
		}
		// MARK: 单行操作弹窗（iPad 自动转 popover）
		.confirmationDialog(
			_actionApp?.name ?? "操作",
			isPresented: Binding(
				get: { _actionApp != nil },
				set: { if !$0 { _actionApp = nil } }
			),
			titleVisibility: .visible
		) {
			if let app = _actionApp {
				Button("签名 IPA", systemImage: "signature") {
					_signingApp = app
					_isSigningActive = true
				}
				Button("查看描述", systemImage: "info.circle") {
					_infoApp = app
					_isInfoActive = true
				}
				Button("导出", systemImage: "square.and.arrow.up") {
					installAppPresenting = AnyApp(base: app, archive: true)
				}
				Button("删除", systemImage: "trash", role: .destructive) {
					_deleteApp = app
				}
			}
			Button("取消", role: .cancel) {}
		}
		// MARK: 删除二次确认（§2.2：说明影响范围）
		.alert(
			"删除「\(_deleteApp?.name ?? "")」？",
			isPresented: Binding(
				get: { _deleteApp != nil },
				set: { if !$0 { _deleteApp = nil } }
			)
		) {
			Button("删除", role: .destructive) {
				if let app = _deleteApp {
					Storage.shared.deleteApp(for: app)
					GeekToast.show("已删除")
				}
			}
			Button("取消", role: .cancel) {}
		} message: {
			Text("将同时删除本地 IPA 文件与关联记录，此操作不可恢复。")
		}
		// MARK: 批量删除二次确认
		.alert(
			"删除选中的 \(_selection.count) 个 IPA？",
			isPresented: $_isBatchDeleteConfirming
		) {
			Button("删除", role: .destructive) { _deleteSelected() }
			Button("取消", role: .cancel) {}
		} message: {
			Text("将同时删除这些 IPA 的本地文件与关联记录，此操作不可恢复。")
		}
		// MARK: push 签名配置页
		.navigationDestination(isPresented: $_isSigningActive) {
			if let app = _signingApp {
				// onFinished：签名完成/关闭时由配置页回调，重置导航状态整栈弹回列表（问题 2/3）
				SigningConfigView(app: app, onFinished: {
					_isSigningActive = false
				})
			}
		}
		// MARK: push 描述页（现有 LibraryInfoView）
		.navigationDestination(isPresented: $_isInfoActive) {
			if let app = _infoApp {
				LibraryInfoView(app: app)
			}
		}
		// MARK: 多选时的批量操作（§2.2：导航栏右侧变为 删除 / 导出）
		.toolbar {
			if _isEditing {
				ToolbarItemGroup(placement: .navigationBarTrailing) {
					Button("导出") { _exportSelected() }
						.disabled(_selection.isEmpty || _isBatchExporting)
					Button("删除", role: .destructive) { _isBatchDeleteConfirming = true }
						.disabled(_selection.isEmpty || _isBatchExporting)
						.foregroundStyle(Color.geekDanger)
				}
			}
		}
		.onChange(of: _isEditing) { editing in
			if !editing { _selection.removeAll() }
		}
	}
}

// MARK: - Extension: 列表行
extension AppsImportedListView {
	@ViewBuilder
	private func _row(for app: Imported) -> some View {
		let uuid = app.uuid ?? ""
		let isSelected = _selection.contains(uuid)
		
		HStack(spacing: 12) {
			if _isEditing {
				Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
					.font(.title2)
					.foregroundStyle(isSelected ? Color.geekPrimary : Color.secondary)
			}
			
			FRAppIconView(app: app, size: 60)
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			
			VStack(alignment: .leading, spacing: 3) {
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					Text(app.name ?? "未知应用")
						.font(.body.weight(.semibold))
						.lineLimit(1)
					if let version = app.version {
						Text(version)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.lineLimit(1)
					}
				}
				// §2.1：始终展示原始 IPA 的 Bundle ID / 大小 / 导入时间，签名后不刷新
				HStack(spacing: 4) {
					Text(app.identifier ?? "未知 Bundle ID")
					Text("·")
					AppDirectorySizeText(app: app)
					Text("·")
					Text(geekFormatDate(app.date))
				}
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(1)
			}
			
			Spacer(minLength: 4)
			
			if !_isEditing {
				// §2.2：右侧状态标签仅「未签名」一种
				GeekTag(text: "未签名", color: .geekWarning)
			}
		}
		.frame(minHeight: 44)
		.padding(.vertical, 4)
		.contentShape(Rectangle())
		.onTapGesture {
			if _isEditing {
				_toggleSelection(uuid)
			} else {
				_actionApp = app
			}
		}
		.onLongPressGesture {
			// 长按进入多选并选中当前行（§2.2）
			guard !_isEditing, !uuid.isEmpty else { return }
			withAnimation { editMode = .active }
			_selection.insert(uuid)
		}
	}
}

// MARK: - Extension: 批量操作
extension AppsImportedListView {
	private func _toggleSelection(_ uuid: String) {
		guard !uuid.isEmpty else { return }
		if _selection.contains(uuid) {
			_selection.remove(uuid)
		} else {
			_selection.insert(uuid)
		}
	}
	
	private var _selectedApps: [Imported] {
		_importedApps.filter { app in
			guard let uuid = app.uuid else { return false }
			return _selection.contains(uuid)
		}
	}
	
	/// 批量删除走 Storage.shared.deleteApp(for:)
	private func _deleteSelected() {
		let apps = _selectedApps
		for app in apps {
			Storage.shared.deleteApp(for: app)
		}
		_selection.removeAll()
		editMode = .inactive
		GeekToast.show("已删除 \(apps.count) 个 IPA")
	}
	
	/// 批量导出：逐个归档为 IPA 后统一调起系统分享面板
	private func _exportSelected() {
		// ArchiveHandler.moveToArchive 强依赖 name/version，先过滤
		let apps = _selectedApps.filter { $0.name != nil && $0.version != nil }
		guard !apps.isEmpty else {
			GeekToast.show("所选 IPA 信息不完整，无法导出", icon: "xmark.circle.fill")
			return
		}
		_isBatchExporting = true
		Task {
			var urls: [URL] = []
			for app in apps {
				do {
					let viewModel = InstallerStatusViewModel()
					let handler = ArchiveHandler(app: app, viewModel: viewModel)
					try await handler.move()
					let package = try await handler.archive()
					if let dest = try await handler.moveToArchive(package) {
						urls.append(dest)
					}
				} catch {
					// 单个失败不阻断其余导出
				}
			}
			await MainActor.run {
				_isBatchExporting = false
				if urls.isEmpty {
					GeekToast.show("导出失败，未能生成 IPA 文件", icon: "xmark.circle.fill")
				} else {
					UIActivityViewController.show(activityItems: urls)
				}
			}
		}
	}
}
