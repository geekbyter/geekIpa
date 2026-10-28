//
//  AppsSignedListView.swift
//  geekIpa
//
//  已签名列表（规格书 §2.5）：签名时间倒序，顶部 ExpiringAppsBanner，
//  行内嵌 SignedAppExpiryRow（剩余有效期）；按「源 IPA + BundleID + App 名」去重展示。
//

import SwiftUI
import CoreData

struct AppsSignedListView: View {
	/// 安装 / 导出弹窗由 AppsView 统一承载
	@Binding var installAppPresenting: AnyApp?
	
	@State private var _actionApp: Signed?   // 操作弹窗对象
	@State private var _deleteApp: Signed?   // 删除二次确认对象
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .default
	) private var _signedApps: FetchedResults<Signed>
	
	/// §2.5 去重：判定键 = 来源 URL + 签名后 BundleID + 签名后 App 名，同键只保留最新一条。
	private var _dedupedApps: [Signed] {
		var seen = Set<String>()
		var result: [Signed] = []
		for app in _signedApps { // FetchRequest 已按签名时间倒序，先遇到的即最新
			let sourceKey: String
			if let source = app.source {
				sourceKey = source.absoluteString
			} else {
				sourceKey = "local"
			}
			let key = [sourceKey, app.identifier ?? "", app.name ?? ""].joined(separator: "|")
			if seen.insert(key).inserted {
				result.append(app)
			}
		}
		return result
	}
	
	// MARK: Body
	var body: some View {
		VStack(spacing: 0) {
			// 临期横幅（≤2 天到期时出现，Renewal 模块提供）
			ExpiringAppsBanner()
				.padding(.top, 4)
			
			List {
				ForEach(_dedupedApps, id: \.uuid) { app in
					_row(for: app)
				}
			}
			.listStyle(.insetGrouped)
		}
		.overlay {
			if _dedupedApps.isEmpty {
				GeekEmptyStateView(
					icon: "checkmark.seal",
					title: "暂无已签名 IPA",
					message: "在「已导入」列表选择一个 IPA 开始签名"
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
				Button("安装", systemImage: "square.and.arrow.down") {
					installAppPresenting = AnyApp(base: app)
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
		// MARK: 删除二次确认（§2.5：只删除该已签名产物，不影响源 IPA）
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
			Text("只删除该已签名产物，不影响源 IPA 文件，此操作不可恢复。")
		}
	}
}

// MARK: - Extension: 列表行
extension AppsSignedListView {
	@ViewBuilder
	private func _row(for app: Signed) -> some View {
		HStack(spacing: 12) {
			FRAppIconView(app: app, size: 60)
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			
			VStack(alignment: .leading, spacing: 3) {
				Text(app.name ?? "未知应用")
					.font(.body.weight(.semibold))
					.lineLimit(1)
				// §2.5：展示签名时改写后的 Bundle ID
				Text(app.identifier ?? "未知 Bundle ID")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				Text("证书：\(_certificateName(for: app))")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.lineLimit(1)
				HStack(spacing: 8) {
					Text("签名于 \(geekFormatDate(app.date))")
						.font(.caption2)
						.foregroundStyle(.secondary)
					// 剩余有效期徽章 + 立即续签（Renewal 模块提供）
					SignedAppExpiryRow(app: app)
				}
			}
			
			Spacer(minLength: 0)
		}
		.frame(minHeight: 44)
		.padding(.vertical, 4)
		.contentShape(Rectangle())
		.onTapGesture { _actionApp = app }
	}
	
	private func _certificateName(for app: Signed) -> String {
		Storage.shared.getCertificate(from: app)?.nickname ?? "未关联证书"
	}
}
