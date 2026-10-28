//
//  RenewalViews.swift
//  geekIpa
//
//  续签提醒 + 免费名额管理的 SwiftUI 视图。
//  字符串全部简体中文硬编码（本模块不走 .localized）。
//

import SwiftUI
import CoreData

// MARK: - ExpiringAppsBanner

/// 有 App ≤2 天到期时显示的横幅，点击展开列表。
///
/// WIRE: 挂载到 LibraryView 的 NBListAdaptable 顶部（NBSection("Signed") 之前）：
///     ExpiringAppsBanner()
/// 依赖 LibraryView 注入的 managedObjectContext（@FetchRequest）。
struct ExpiringAppsBanner: View {
	@StateObject private var renewalManager = RenewalManager.shared
	@State private var _isExpanded = false

	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
	) private var _signedApps: FetchedResults<Signed>

	private var _expiringApps: [Signed] {
		_signedApps.filter { app in
			guard
				let uuid = app.uuid,
				let days = RenewalTracker.shared.daysRemaining(uuid: uuid)
			else { return false }
			return days <= 2
		}
	}

	var body: some View {
		if !_expiringApps.isEmpty {
			VStack(alignment: .leading, spacing: 10) {
				Button {
					withAnimation { _isExpanded.toggle() }
				} label: {
					HStack {
						Image(systemName: "exclamationmark.triangle.fill")
							.foregroundStyle(.orange)
						Text("\(_expiringApps.count) 个 App 的签名即将到期")
							.font(.headline)
							.foregroundStyle(.primary)
						Spacer()
						Image(systemName: _isExpanded ? "chevron.up" : "chevron.down")
							.font(.footnote.bold())
							.foregroundStyle(.secondary)
					}
				}
				.buttonStyle(.plain)

				if _isExpanded {
					ForEach(_expiringApps, id: \.uuid) { app in
						SignedAppExpiryRow(app: app)
					}
				}
			}
			.padding(12)
			.background(
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.fill(Color.orange.opacity(0.12))
			)
			.padding(.horizontal)
		}
	}
}

// MARK: - SignedAppExpiryRow

/// 已签 App 行尾的到期倒计时徽章 + 「立即续签」按钮（仅 Apple ID 类显示按钮）。
///
/// WIRE: 挂载到 LibraryCellView 的 HStack 行尾（_buttonActions 内 app.isSigned 分支）：
///     if let signed = app as? Signed { SignedAppExpiryRow(app: signed) }
/// 也可独立用在任意已签 App 列表行。
struct SignedAppExpiryRow: View {
	@StateObject private var renewalManager = RenewalManager.shared

	let app: Signed

	private var _uuid: String { app.uuid ?? "" }

	private var _days: Int? {
		RenewalTracker.shared.daysRemaining(uuid: _uuid)
	}

	private var _isAppleIDSigned: Bool {
		RenewalTracker.shared.kind(for: _uuid) == .appleID
	}

	private var _isRefreshing: Bool {
		renewalManager.refreshingUUIDs.contains(_uuid)
	}

	private var _badgeText: String {
		guard let days = _days else { return "" }
		return days == 0 ? "今天到期" : "剩 \(days) 天"
	}

	private var _badgeColor: Color {
		guard let days = _days else { return .secondary }
		if days == 0 { return .red }
		if days <= 2 { return .orange }
		return .green
	}

	var body: some View {
		HStack(spacing: 8) {
			if _days != nil {
				Text(_badgeText)
					.font(.caption.bold())
					.foregroundStyle(.white)
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(_badgeColor.opacity(0.9))
					.clipShape(Capsule())
			}

			if _isAppleIDSigned {
				Button {
					renewalManager.refreshNowWithUI(uuid: _uuid)
				} label: {
					if _isRefreshing {
						ProgressView()
							.padding(.horizontal, 8)
					} else {
						Text("立即续签")
							.font(.caption.bold())
					}
				}
				.buttonStyle(.borderless)
				.tint(.accentColor)
				.disabled(_isRefreshing)
			}
		}
	}
}

// MARK: - SlotStatusView

/// 免费名额占用（x/3）+ 各 App ID 列表 + 「释放名额」按钮。
///
/// WIRE: 挂载到 SettingsView 的账户相关 Section（NavigationLink 推入）：
///     NavigationLink("免费名额管理") { SlotStatusView() }
struct SlotStatusView: View {
	@StateObject private var slotManager = SlotManager.shared
	@State private var _slotPendingRelease: AppIDSlot?

	var body: some View {
		List {
			switch slotManager.state {
			case .unavailable:
				Section {
					Label("未登录 Apple ID", systemImage: "person.crop.circle.badge.exclamationmark")
						.font(.headline)
					Text("登录 Apple ID 后可查看免费名额（3 个上限）。证书签名（企业 / UDID 证书）的 App 不占用名额，到期日以证书有效期为准。")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}

			case .loading, .idle:
				HStack {
					Spacer()
					ProgressView()
					Spacer()
				}

			case .failed(let message):
				Section {
					Label("名额信息加载失败", systemImage: "exclamationmark.triangle")
						.font(.headline)
					Text(message)
						.font(.footnote)
						.foregroundStyle(.secondary)
					Button("重试") {
						Task { await slotManager.loadSlots() }
					}
				}

			case .loaded:
				Section {
					VStack(alignment: .leading, spacing: 8) {
						HStack {
							Text("已用名额")
							Spacer()
							Text("\(slotManager.usedCount)/\(SlotManager.capacity)")
								.font(.headline)
								.foregroundStyle(slotManager.usedCount >= SlotManager.capacity ? .red : .primary)
						}
						ProgressView(
							value: Double(slotManager.usedCount),
							total: Double(SlotManager.capacity)
						)
						.tint(slotManager.usedCount >= SlotManager.capacity ? .red : .accentColor)

						if slotManager.usedCount >= SlotManager.capacity {
							Text("名额已满：新 App 将无法用此 Apple ID 签名，请先释放名额。")
								.font(.footnote)
								.foregroundStyle(.red)
						}
					}
				} header: {
					Text("免费名额")
				} footer: {
					Text("免费 Apple ID 最多同时激活 \(SlotManager.capacity) 个 App。释放名额只删除描述文件，请同时在桌面长按删除对应 App 本体。")
				}

				Section("已注册的 App ID") {
					ForEach(slotManager.slots) { slot in
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(slot.name)
									.font(.body)
								Text(slot.bundleIdentifier)
									.font(.caption)
									.foregroundStyle(.secondary)
								if let expiration = slot.expirationDate {
									Text("描述文件到期：\(expiration.formatted(date: .numeric, time: .omitted))")
										.font(.caption2)
										.foregroundStyle(.secondary)
								}
							}
							Spacer()
							Button("释放名额", role: .destructive) {
								_slotPendingRelease = slot
							}
							.buttonStyle(.borderless)
							.font(.subheadline.bold())
						}
					}
				}
			}
		}
		.navigationTitle("免费名额")
		.onAppear {
			Task { await slotManager.loadSlots() }
		}
		.refreshable {
			await slotManager.loadSlots()
		}
		.confirmationDialog(
			"释放名额？",
			isPresented: Binding(
				get: { _slotPendingRelease != nil },
				set: { if !$0 { _slotPendingRelease = nil } }
			),
			titleVisibility: .visible
		) {
			if let slot = _slotPendingRelease {
				Button("释放「\(slot.name)」的名额", role: .destructive) {
					Task { await slotManager.freeSlot(slot) }
				}
			}
			Button("取消", role: .cancel) {}
		} message: {
			Text("将删除该 App ID 的描述文件以腾出名额。App 本体需回到桌面长按删除。")
		}
		.alert(
			"提示",
			isPresented: Binding(
				get: { slotManager.lastMessage != nil },
				set: { if !$0 { slotManager.lastMessage = nil } }
			)
		) {
			Button("好", role: .cancel) {}
		} message: {
			Text(slotManager.lastMessage ?? "")
		}
	}
}
