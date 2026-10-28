//
//  SlotManager.swift
//  geekIpa
//
//  免费名额管理：一个免费 Apple ID 同时只能激活 3 个 App。
//  通过 GeekIpaServices.shared.appIDLister 列出 / 删除 App ID 描述文件。
//  未登录（lister 为 nil）时状态为 .unavailable，静默降级，不报错。
//

import Foundation
import Combine
import AltSign

// MARK: - 视图模型

/// 一个已注册的 App ID（占一个免费名额）
struct AppIDSlot: Identifiable, Equatable {
	/// 稳定标识（bundleIdentifier）
	let id: String
	let name: String
	let bundleIdentifier: String
	let expirationDate: Date?
}

// MARK: - SlotManager

final class SlotManager: ObservableObject {
	static let shared = SlotManager()

	/// 免费 Apple ID 的 App ID 上限
	static let capacity = 3

	enum State: Equatable {
		/// 未登录 Apple ID，名额功能不可用
		case unavailable
		case idle
		case loading
		case loaded
		case failed(String)
	}

	@Published private(set) var state: State = .idle
	@Published private(set) var slots: [AppIDSlot] = []
	/// 操作结果提示（释放成功 / 失败原因），由视图层弹窗展示
	@Published var lastMessage: String?

	var usedCount: Int { slots.count }
	var freeCount: Int { max(0, Self.capacity - usedCount) }

	/// bundleIdentifier → 原始 ALTAppID（deleteProfile 需要原始对象）
	private var _rawAppIDs: [String: ALTAppID] = [:]

	private init() {}

	// MARK: - 加载

	@MainActor
	func loadSlots() async {
		guard let lister = GeekIpaServices.shared.appIDLister else {
			state = .unavailable
			slots = []
			_rawAppIDs = [:]
			return
		}

		state = .loading
		do {
			let appIDs = try await lister.listAppIDs()
			_rawAppIDs = Dictionary(appIDs.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { _, last in last })
			slots = appIDs
				.map {
					AppIDSlot(
						id: $0.bundleIdentifier,
						name: $0.name,
						bundleIdentifier: $0.bundleIdentifier,
						expirationDate: $0.expirationDate
					)
				}
				.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
			state = .loaded
		} catch {
			state = .failed(error.localizedDescription)
		}
	}

	// MARK: - 释放名额

	/// 删除该 App ID 的描述文件以释放一个免费名额，成功后刷新列表。
	/// 注意：仅删除描述文件，桌面上的 App 本体需用户自行长按删除（文案在视图层提示）。
	@MainActor
	func freeSlot(_ slot: AppIDSlot) async {
		guard let lister = GeekIpaServices.shared.appIDLister else {
			state = .unavailable
			return
		}
		guard let raw = _rawAppIDs[slot.id] else { return }

		do {
			try await lister.deleteProfile(for: raw)
			lastMessage = "已释放「\(slot.name)」占用的名额。请回到桌面长按删除对应 App，避免它过期后无法打开。"
			await loadSlots()
		} catch {
			lastMessage = "释放名额失败：\(error.localizedDescription)"
		}
	}

	/// 按 bundleIdentifier 释放（供非视图调用方使用）
	@MainActor
	func freeSlot(bundleIdentifier: String) async {
		guard let slot = slots.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
		await freeSlot(slot)
	}
}
