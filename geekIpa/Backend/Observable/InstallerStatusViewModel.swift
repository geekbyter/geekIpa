//
//  InstallerStatusViewModel.swift
//  geekIpa
//
//  安装流程状态模型。
//  说明：原先由 IDeviceSwift 包提供，现本地自实现，以便完全移除该依赖。
//

import Foundation
import Combine
import NimbleExtensions

/// 安装流程状态
final class InstallerStatusViewModel: ObservableObject {

	enum InstallerStatus {
		case none
		case ready
		case sendingManifest
		case sendingPayload
		case installing
		case completed(Result<Void, Error>)
		case broken(Error)
	}

	@Published var status: InstallerStatus
	@Published var uploadProgress: Double = 0.0
	@Published var packageProgress: Double = 0.0
	@Published var installProgress: Double = 0.0

	/// 是否走 USB / installation proxy 通道（本 App 恒为 false，保留字段以兼容调用点）
	var isIDevice: Bool

	var overallProgress: Double {
		if isIDevice {
			(installProgress + uploadProgress + packageProgress) / 3.0
		} else {
			(installProgress + packageProgress) / 2.0
		}
	}

	var isCompleted: Bool {
		if case .completed = status {
			return true
		}
		return false
	}

	init(
		status: InstallerStatus = .none,
		isIdevice: Bool = true
	) {
		self.status = status
		self.isIDevice = isIdevice
	}
}

// MARK: - 展示派生属性

extension InstallerStatusViewModel {
	var statusImage: String {
		switch status {
		case .none: "archivebox.fill"
		case .ready: "app.gift"
		case .sendingManifest, .sendingPayload: "paperplane.fill"
		case .installing: "square.and.arrow.down"
		case .completed: "app.badge.checkmark"
		case .broken: "exclamationmark.triangle.fill"
		}
	}

	var statusLabel: String {
		switch status {
		case .none: .localized("Packaging")
		case .ready: .localized("Ready")
		case .sendingManifest: .localized("Sending Manifest")
		case .sendingPayload: .localized("Sending Payload")
		case .installing: .localized("Installing")
		case .completed: .localized("Completed")
		case .broken: .localized("Error")
		}
	}
}
