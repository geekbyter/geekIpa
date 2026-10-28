//
//  DeviceView.swift
//  geekIpa
//
//  设备页（规格书 §4）：顶部状态卡 + 分组列表。
//  设备信息 / 存储 / App 概况 / 开发者模式引导。
//  所有数据 onAppear + Task 异步加载，失败项显示「—」，不崩溃。
//
//  CONTRACT: Tab 框架直接引用 `DeviceView()`，签名勿改。
//

import SwiftUI
import UIKit
import Darwin
import Network
import CoreData
import IDeviceSwift

// CONTRACT: 公共契约 —— Tab 框架直接引用
struct DeviceView: View {
	init() {}

	@StateObject private var _model = DeviceViewModel()

	// 本工具已签名应用（签名时间倒序）
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
	) private var _signedApps: FetchedResults<Signed>

	@State private var _devModeAlert = false
	@State private var _showUDIDSheet = false
	@State private var _udidInput = ""
	@State private var _udidError: String?

	var body: some View {
		List {
			// MARK: 顶部状态卡
			Section {
				_statusCard()
			}
			.listRowBackground(Color.clear)
			.listRowInsets(EdgeInsets())

			// MARK: 设备信息
			Section("设备信息") {
				LabeledContent("iPhone 型号", value: _model.modelName)
				LabeledContent("iOS 版本", value: _model.systemVersion)
				_udidRow()
				LabeledContent("架构", value: "arm64")
			}

			// MARK: 开发者模式
			Section {
				HStack {
					Label("开发者模式", systemImage: "hammer")
					Spacer()
					Text("未开启时部分功能受限")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Button("查看开启指引") {
					_devModeAlert = true
				}
				.tint(.geekPrimary)
			} footer: {
				Text("公开 API 无法读取开发者模式开关状态，如遇安装失败请先前往系统设置确认已开启。")
			}

			// MARK: 存储
			Section("存储") {
				LabeledContent("总容量", value: DeviceViewModel.bytes(_model.totalBytes))
				LabeledContent("已用", value: DeviceViewModel.bytes(_model.usedBytes))
				LabeledContent("可用", value: DeviceViewModel.bytes(_model.freeBytes))
				if let total = _model.totalBytes, let used = _model.usedBytes, total > 0 {
					let ratio = Double(used) / Double(total)
					ProgressView(value: Double(used), total: Double(total))
						.tint(ratio > 0.9 ? .geekWarning : .geekPrimary)
					if ratio > 0.9 {
						Text("可用空间不足 10%，建议清理后再进行签名与安装。")
							.font(.caption)
							.foregroundStyle(Color.geekWarning)
					}
				}
			}

			// MARK: App 概况
			Section("App 概况") {
				LabeledContent("本工具已签名", value: "\(_signedApps.count) 个")
				if _signedApps.isEmpty {
					Text("暂无签名记录")
						.font(.footnote)
						.foregroundStyle(.secondary)
				} else {
					ForEach(Array(_signedApps.prefix(3)), id: \.uuid) { app in
						HStack {
							VStack(alignment: .leading, spacing: 2) {
								Text(app.name ?? "未知应用")
									.font(.body)
									.lineLimit(1)
								Text(app.identifier ?? "—")
									.font(.caption)
									.foregroundStyle(.secondary)
									.lineLimit(1)
							}
							Spacer()
							VStack(alignment: .trailing, spacing: 2) {
								if let version = app.version {
									Text("v\(version)")
										.font(.caption)
										.foregroundStyle(.secondary)
								}
								Text(GeekDateFormat.dayTimeString(app.date))
									.font(.caption)
									.foregroundStyle(.secondary)
							}
						}
					}
				}
			}
		}
		.listStyle(.insetGrouped)
		.navigationTitle("设备")
		.toolbar {
			ToolbarItem(placement: .navigationBarTrailing) {
				NavigationLink {
					SettingsView()
				} label: {
					Image(systemName: "gearshape")
				}
			}
		}
		.task {
			_model.load()
		}
		.refreshable {
			_model.load()
			try? await Task.sleep(nanoseconds: 300_000_000)
		}
		.alert("如何开启开发者模式", isPresented: $_devModeAlert) {
			Button("知道了", role: .cancel) {}
		} message: {
			Text("前往 设置 → 隐私与安全性 → 开发者模式，开启开关后按提示重启设备，重启后在弹窗中选择「打开」。")
		}
	}

	// MARK: - 顶部状态卡
	@ViewBuilder
	private func _statusCard() -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Image(systemName: "iphone")
					.font(.system(size: 30, weight: .regular))
					.foregroundStyle(Color.geekPrimary)
				VStack(alignment: .leading, spacing: 2) {
					Text(_model.deviceName)
						.font(.title3.weight(.semibold))
					Text(_model.modelName)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Spacer()
			}

			HStack(spacing: 8) {
				Circle()
					.fill(DeviceIdentity.hasUDID ? Color.geekSuccess : Color.geekWarning)
					.frame(width: 8, height: 8)
				Text(DeviceIdentity.hasUDID ? "UDID 已录入" : "UDID 未录入")
					.font(.footnote.weight(.medium))
					.foregroundStyle(DeviceIdentity.hasUDID ? Color.geekSuccess : Color.geekWarning)
				Spacer()
				if !DeviceIdentity.hasUDID {
					Text("录入后才能用 Apple ID 签名")
						.font(.caption2)
						.foregroundStyle(.secondary)
				}
			}
		}
		.padding(16)
		.background(
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.fill(Color.geekCardBackground)
		)
	}

	// MARK: - UDID 行（点击录入 / 已录入可复制）
	@ViewBuilder
	private func _udidRow() -> some View {
		HStack {
			Button {
				_udidInput = DeviceIdentity.udid ?? ""
				_showUDIDSheet = true
			} label: {
				HStack {
					Text("UDID")
						.foregroundStyle(.primary)
					Spacer()
					Text(DeviceIdentity.udid ?? "未录入，点击录入")
						.font(.footnote)
						.foregroundStyle(DeviceIdentity.udid == nil ? Color.geekWarning : .secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			.buttonStyle(.plain)

			if let udid = DeviceIdentity.udid {
				Button {
					UIPasteboard.general.string = udid
					GeekToast.show("已复制")
				} label: {
					Image(systemName: "doc.on.doc")
				}
				.buttonStyle(.borderless)
				.tint(.geekPrimary)
			}
		}
		.sheet(isPresented: $_showUDIDSheet) {
			_udidInputSheet()
		}
	}

	// MARK: - UDID 录入面板
	@ViewBuilder
	private func _udidInputSheet() -> some View {
		UDIDAcquireView()
	}

	// MARK: - 网络行（状态点）
}

// MARK: - 设备数据模型

final class DeviceViewModel: ObservableObject {
	@Published var deviceName: String = UIDevice.current.name
	@Published var systemVersion: String = UIDevice.current.systemVersion
	@Published var modelName: String = "—"
	@Published var udid: String?
	@Published var pairingFileExists = false
	@Published var heartbeatRunning = false
	@Published var totalBytes: Int64?
	@Published var freeBytes: Int64?

	var usedBytes: Int64? {
		guard let totalBytes, let freeBytes else { return nil }
		return max(0, totalBytes - freeBytes)
	}


	init() {
	}

	deinit {
		_monitor.cancel()
	}

	/// 加载全部设备数据；任一环节失败保持默认值 / nil，由 UI 显示「—」
	func load() {
		DispatchQueue.global(qos: .userInitiated).async {
			let model = Self.modelName()
			let udid = GeekDeviceIdentity.udid
			let pairingExists = GeekDeviceIdentity.exists
			let heartbeatRunning = HeartbeatManager.shared.heartbeatThread?.isExecuting ?? false
			let (total, free) = Self.storageSizes()
			let name = UIDevice.current.name
			let version = UIDevice.current.systemVersion

			DispatchQueue.main.async {
				self.modelName = model
				self.udid = udid
				self.pairingFileExists = pairingExists
				self.heartbeatRunning = heartbeatRunning
				self.totalBytes = total
				self.freeBytes = free
				self.deviceName = name
				self.systemVersion = version
			}
		}
	}

	// MARK: 网络监听


	// MARK: 存储容量

	static func storageSizes() -> (total: Int64?, free: Int64?) {
		let home = URL(fileURLWithPath: NSHomeDirectory())
		if let values = try? home.resourceValues(forKeys: [
			.volumeTotalCapacityKey,
			.volumeAvailableCapacityForImportantUsageKey
		]) {
			let total = values.volumeTotalCapacity.map { Int64($0) }
			let free = values.volumeAvailableCapacityForImportantUsage
			if total != nil || free != nil { return (total, free) }
		}
		if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
			let total = (attributes[.systemSize] as? NSNumber)?.int64Value
			let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
			return (total, free)
		}
		return (nil, nil)
	}

	static func bytes(_ value: Int64?) -> String {
		guard let value else { return "—" }
		return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
	}

	// MARK: 机型映射

	static func machineIdentifier() -> String {
		var systemInfo = utsname()
		uname(&systemInfo)
		return withUnsafePointer(to: &systemInfo.machine) { pointer in
			pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
				String(validatingUTF8: $0) ?? "unknown"
			}
		}
	}

	static func modelName() -> String {
		let machine = machineIdentifier()
		return _modelMap[machine] ?? machine
	}

	private static let _modelMap: [String: String] = [
		// iPhone
		"iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE（第 1 代）",
		"iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7",
		"iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
		"iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
		"iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
		"iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
		"iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
		"iPhone11,8": "iPhone XR",
		"iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
		"iPhone12,8": "iPhone SE（第 2 代）",
		"iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
		"iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
		"iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
		"iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
		"iPhone14,6": "iPhone SE（第 3 代）",
		"iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
		"iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
		"iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
		"iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
		"iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
		"iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
		// iPad（常见型号，识别不了回落原始标识）
		"iPad7,5": "iPad（第 6 代）", "iPad7,6": "iPad（第 6 代）",
		"iPad7,11": "iPad（第 7 代）", "iPad7,12": "iPad（第 7 代）",
		"iPad11,6": "iPad（第 8 代）", "iPad11,7": "iPad（第 8 代）",
		"iPad12,1": "iPad（第 9 代）", "iPad12,2": "iPad（第 9 代）",
		"iPad13,18": "iPad（第 10 代）", "iPad13,19": "iPad（第 10 代）",
		"iPad8,1": "iPad Pro 11（第 1 代）", "iPad8,3": "iPad Pro 11（第 1 代）",
		"iPad8,9": "iPad Pro 11（第 2 代）", "iPad8,10": "iPad Pro 11（第 2 代）",
		"iPad13,4": "iPad Pro 11（第 3 代）", "iPad13,8": "iPad Pro 11（第 3 代）",
		"iPad14,3": "iPad Pro 11（第 4 代）", "iPad14,4": "iPad Pro 11（第 4 代）",
		"iPad13,1": "iPad Air（第 4 代）", "iPad13,2": "iPad Air（第 4 代）",
		"iPad13,16": "iPad Air（第 5 代）", "iPad13,17": "iPad Air（第 5 代）",
		"iPad14,8": "iPad Air 11（M2）", "iPad14,10": "iPad Air 13（M2）",
		"iPad14,1": "iPad mini（第 6 代）", "iPad14,2": "iPad mini（第 6 代）"
	]
}
