//
//  RenewalManager.swift
//  geekIpa
//
//  续签调度：第 5 天本地通知提醒 + 一键续签（拉新描述文件 → 重签 → 走 itms 安装）。
//  后台任务（BGAppRefreshTask）只发通知，不做真续签（续签要联网 + 装包，后台不可靠）。
//

import Foundation
import Combine
import UIKit
import UserNotifications
import CoreData
import NimbleExtensions
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

// MARK: - 错误

enum RenewalError: Error, LocalizedError {
	/// 未登录 Apple ID（GeekIpaServices.profileRefresher 为 nil）
	case notLoggedIn
	case appNotFound
	case missingBundleIdentifier
	case signingFailed(Error)

	var errorDescription: String? {
		switch self {
		case .notLoggedIn: "未登录 Apple ID，无法续签免费签名"
		case .appNotFound: "找不到该已签 App"
		case .missingBundleIdentifier: "该 App 缺少 Bundle Identifier，无法续签"
		case .signingFailed(let error): "重签失败：\(error.localizedDescription)"
		}
	}
}

// MARK: - RenewalManager

final class RenewalManager: ObservableObject {
	static let shared = RenewalManager()

	/// 后台刷新任务标识符：运行时从真实 bundle id 拼接，与 Info.plist 的
	/// $(PRODUCT_BUNDLE_IDENTIFIER).userTask.* 前缀对齐（兼容 Debug 的 TeamID 后缀）
	static var backgroundTaskIdentifier: String {
		(Bundle.main.bundleIdentifier ?? "com.geekipa.ios") + ".userTask.refresh"
	}

	/// 本地通知 identifier 前缀
	private static let _notificationPrefix = "geekipa.renewal."

	@Published private(set) var isRefreshing = false
	@Published private(set) var refreshingUUIDs: Set<String> = []

	private init() {}

	// MARK: - 通知权限

	func requestNotificationPermission() {
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
	}

	// MARK: - 到期提醒（第 5 天 09:00）

	/// 为所有 Apple ID 类已签 App 重排「第 5 天 09:00」本地通知。
	/// 幂等：先清掉本模块的所有 pending 通知再重排。签名完成 / 续签完成 / 删除 App 后都应调用。
	func scheduleExpiryReminders() {
		let center = UNUserNotificationCenter.current()
		center.getPendingNotificationRequests { [weak self] requests in
			guard let self else { return }
			let stale = requests
				.map(\.identifier)
				.filter { $0.hasPrefix(Self._notificationPrefix) }
			center.removePendingNotificationRequests(withIdentifiers: stale)
			self._scheduleAll(on: center)
		}
	}

	/// 删除某个 App 的全部提醒（删除 App / 释放名额时调用）
	func removeReminders(for uuid: String) {
		UNUserNotificationCenter.current()
			.removePendingNotificationRequests(withIdentifiers: [Self._notificationID(for: uuid)])
	}

	private static func _notificationID(for uuid: String) -> String {
		"\(_notificationPrefix)\(uuid)"
	}

	private func _scheduleAll(on center: UNUserNotificationCenter) {
		let calendar = Calendar.current
		let now = Date()

		for record in RenewalTracker.shared.allRecords() where record.kind == .appleID {
			// 第 5 天（自签名时刻起算）当天 09:00
			guard
				let day5 = calendar.date(byAdding: .day, value: 5, to: record.signDate),
				let expiry = calendar.date(byAdding: .day, value: 7, to: record.signDate)
			else { continue }

			var components = calendar.dateComponents([.year, .month, .day], from: day5)
			components.hour = 9
			components.minute = 0

			guard let fireDate = calendar.date(from: components), fireDate > now else {
				continue // 已过提醒时间就不再排
			}

			let remainingDays = max(0, Int(expiry.timeIntervalSince(fireDate) / 86400))
			let content = UNMutableNotificationContent()
			content.title = "「\(record.name)」签名即将到期"
			content.body = "免费签名将在 \(remainingDays) 天后过期，打开 geekIpa 点按「立即续签」即可一键续签。"
			content.sound = .default

			let request = UNNotificationRequest(
				identifier: Self._notificationID(for: record.uuid),
				content: content,
				trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
			)
			center.add(request)
		}
	}

	// MARK: - 一键续签

	/// 续签流程（无 UI 依赖，可在任意上下文 await）：
	/// 1. freshProfileData 拉最新描述文件
	/// 2. currentSigningP12 拿当前 Apple ID 开发证书
	/// 3. 落到临时证书目录，走现有 FR.signPackageFile（Zsign）重签原 App
	/// 4. 新 Signed 记录入库后删除旧记录、更新 RenewalTracker、重排提醒
	/// - Returns: 重签后新 Signed 记录的 uuid
	@discardableResult
	func refreshNow(uuid: String) async throws -> String {
		guard let refresher = GeekIpaServices.shared.profileRefresher else {
			throw RenewalError.notLoggedIn
		}
		guard let app = _signedApp(uuid: uuid) else {
			throw RenewalError.appNotFound
		}
		guard let bundleID = app.identifier else {
			throw RenewalError.missingBundleIdentifier
		}
		let appName = app.name ?? bundleID

		// 1. 新描述文件 + 2. 当前签名证书
		let profileData = try await refresher.freshProfileData(bundleIdentifier: bundleID, appName: appName)
		let (p12Data, p12Password) = try refresher.currentSigningP12()

		// 3. 写到临时证书目录（ZsignHandler 只认 Documents/Certificates/<uuid>/*.p12 + *.mobileprovision）
		let fileManager = FileManager.default
		let tempCertUUID = "Renewal_\(UUID().uuidString)"
		let tempCertDir = fileManager.certificates(tempCertUUID)
		try fileManager.createDirectoryIfNeeded(at: tempCertDir)
		try p12Data.write(to: tempCertDir.appendingPathComponent("renewal.p12"), options: .atomic)
		try profileData.write(to: tempCertDir.appendingPathComponent("renewal.mobileprovision"), options: .atomic)

		do {
			let newUUID = try await _resign(
				app: app,
				tempCertUUID: tempCertUUID,
				p12Password: p12Password
			)

			// 4. 入库成功后：更新跟踪、删旧 App、重排提醒
			await MainActor.run {
				RenewalTracker.shared.remove(uuid: uuid)
				RenewalTracker.recordSignedApp(uuid: newUUID, name: appName, kind: .appleID)
				Storage.shared.deleteApp(for: app)
				removeReminders(for: uuid)
				scheduleExpiryReminders()
			}

			try? fileManager.removeFileIfNeeded(at: tempCertDir)
			return newUUID
		} catch {
			try? fileManager.removeFileIfNeeded(at: tempCertDir)
			throw error
		}
	}

	/// 视图层入口：带 isRefreshing 状态、错误弹窗，成功后经
	/// 「geekIpa.installApp」通知进入现有安装管线
	/// （LibraryView 弹出 InstallPreviewView → ServerInstaller 起本地 itms 服务器安装）。
	@MainActor
	func refreshNowWithUI(uuid: String, completion: @escaping (Result<String, Error>) -> Void = { _ in }) {
		guard !refreshingUUIDs.contains(uuid) else { return }
		isRefreshing = true
		refreshingUUIDs.insert(uuid)

		Task {
			defer {
				isRefreshing = false
				refreshingUUIDs.remove(uuid)
			}
			do {
				let newUUID = try await refreshNow(uuid: uuid)
				// 与 SigningView 的 post_installAppAfterSigned 同一路径：
				// LibraryView 监听该通知并对最新签名 App 弹出安装面板
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
					NotificationCenter.default.post(name: Notification.Name("geekIpa.installApp"), object: nil)
				}
				completion(.success(newUUID))
			} catch {
				UIAlertController.showAlertWithOk(
					title: "续签失败",
					message: error.localizedDescription
				)
				completion(.failure(error))
			}
		}
	}

	// MARK: - 重签（复用现有签名管线）

	private func _resign(app: Signed, tempCertUUID: String, p12Password: String) async throws -> String {
		let signStart = Date()
		let oldIdentifier = app.identifier

		// 临时 CertificatePair 仅作 Zsign 的文件定位载体（uuid → 证书目录）。
		// 必须插入 context（游离对象挂进关系会触发 Core Data 跨 context 崩溃），
		// 签名完成后立即删除（ SigningHandler 入库时 save 过 context，所以这里删除后要再 save 一次）。
		let context = Storage.shared.context
		let tempCert: CertificatePair = await context.perform {
			let cert = CertificatePair(context: context)
			cert.uuid = tempCertUUID
			cert.password = p12Password
			cert.date = Date()
			cert.expiration = Date().addingTimeInterval(RenewalTracker.appleIDValidityInterval)
			return cert
		}

		// 续签必须保持身份不变：清空改名 / 改 id / 注入等修改项，只换描述文件重签
		var options = OptionsManager.shared.options
		options.appName = nil
		options.appVersion = nil
		options.appIdentifier = nil
		options.appEntitlementsFile = nil
		options.ppqProtection = false
		options.identifiers = [:]
		options.displayNames = [:]
		options.injectionFiles = []
		options.disInjectionFiles = []
		options.removeFiles = []
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false

		let signError: Error? = await withCheckedContinuation { continuation in
			FR.signPackageFile(
				app,
				using: options,
				icon: nil,
				certificate: tempCert
			) { error in
				continuation.resume(returning: error)
			}
		}

		// 用完即删临时证书对象（含一次 save 把删除落库）
		await context.perform {
			context.delete(tempCert)
			try? context.save()
		}

		if let signError {
			throw RenewalError.signingFailed(signError)
		}

		// SigningHandler 内部生成新 uuid，回调不返回；
		// 取本次签名开始后入库的、同 identifier 的最新 Signed 记录
		let newUUID: String? = await MainActor.run {
			let request: NSFetchRequest<Signed> = Signed.fetchRequest()
			request.predicate = NSPredicate(
				format: "identifier == %@ AND date >= %@",
				oldIdentifier ?? "", signStart as NSDate
			)
			request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
			request.fetchLimit = 1
			return (try? Storage.shared.context.fetch(request))?.first?.uuid
		}

		guard let newUUID else {
			throw RenewalError.appNotFound
		}
		return newUUID
	}

	private func _signedApp(uuid: String) -> Signed? {
		let context = Storage.shared.context
		return context.performAndWait {
			let request: NSFetchRequest<Signed> = Signed.fetchRequest()
			request.predicate = NSPredicate(format: "uuid == %@", uuid)
			request.fetchLimit = 1
			return try? context.fetch(request).first
		}
	}
}

// MARK: - 后台刷新（只发通知，不做真续签）

#if !targetEnvironment(macCatalyst)
extension RenewalManager {

	/// WIRE: AppDelegate —— 在 geekIpaApp.swift 的
	/// application(_:didFinishLaunchingWithOptions:) 里（return true 之前）调用：
	///     RenewalManager.registerBackgroundTasks()
	///     RenewalManager.scheduleAppRefresh()
	/// 注意 BGTaskScheduler.register 必须在启动结束前完成。
	static func registerBackgroundTasks() {
		BGTaskScheduler.shared.register(
			forTaskWithIdentifier: backgroundTaskIdentifier,
			using: nil
		) { task in
			guard let refreshTask = task as? BGAppRefreshTask else {
				task.setTaskCompleted(success: false)
				return
			}
			handleAppRefresh(refreshTask)
		}
	}

	/// 排队下一次后台刷新（明早 09:00 之后）
	static func scheduleAppRefresh() {
		let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
		var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
		components.hour = 9
		components.minute = 0
		let todayNine = Calendar.current.date(from: components) ?? Date()
		request.earliestBeginDate = todayNine > Date()
			? todayNine
			: Calendar.current.date(byAdding: .day, value: 1, to: todayNine)
		try? BGTaskScheduler.shared.submit(request)
	}

	/// 后台执行：重排第 5 天提醒 + 对 ≤2 天到期的 App 立刻补一条通知。
	/// 不做真续签（联网 + 装包在后台不可靠）。
	static func handleAppRefresh(_ task: BGAppRefreshTask? = nil) {
		task?.expirationHandler = {} // 必须在 setTaskCompleted 之前设置

		scheduleAppRefresh() // 先排下一次
		shared.scheduleExpiryReminders()

		let center = UNUserNotificationCenter.current()
		center.getPendingNotificationRequests { pending in
			center.getDeliveredNotifications { delivered in
				let knownIDs = Set(pending.map(\.identifier) + delivered.map(\.request.identifier))
				for record in RenewalTracker.shared.allRecords() where record.kind == .appleID {
					let id = "\(_notificationPrefix)bg.\(record.uuid)"
					guard !knownIDs.contains(id) else { continue }
					guard let days = RenewalTracker.shared.daysRemaining(uuid: record.uuid), days <= 2 else { continue }

					let content = UNMutableNotificationContent()
					content.title = "「\(record.name)」签名即将到期"
					content.body = days == 0
						? "免费签名今天过期，App 将无法打开。请尽快打开 geekIpa 续签。"
						: "免费签名将在 \(days) 天后过期，打开 geekIpa 一键续签。"
					content.sound = .default

					let request = UNNotificationRequest(
						identifier: id,
						content: content,
						trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
					)
					center.add(request)
				}
				task?.setTaskCompleted(success: true)
			}
		}
	}
}
#endif
