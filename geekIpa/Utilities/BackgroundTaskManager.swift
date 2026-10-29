//
//  BackgroundTaskManager.swift
//  geekIpa
//
//  Created by Nagata Asami on 4/1/26.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks
import CryptoKit

@available(iOS 26.0, *)
class BackgroundTaskManager: ObservableObject {
	static let shared = BackgroundTaskManager()
	
	private let baseId = "\(Bundle.main.bundleIdentifier!).userTask"
	
	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []

	/// Info.plist 里允许的后台任务标识符（系统只接受精确匹配，不支持通配符）
	private static let permittedIdentifiers: Set<String> = {
		let list = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
		return Set(list ?? [])
	}()

	/// 动态标识符（含 md5）无法写进 Info.plist，未授权时注册会被系统拒绝甚至抛异常，
	/// 因此这里先自检：不在白名单内就直接跳过，保证下载流程不受影响。
	private func _isPermitted(_ identifier: String) -> Bool {
		Self.permittedIdentifiers.contains(identifier)
	}

	func startTask(for downloadId: String, filename: String) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"

		guard _isPermitted(taskIdentifier) else {
			return
		}

		if !registeredTasks.contains(taskIdentifier) {
			BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
				self.activeTasks[task.identifier] = task
				
				task.expirationHandler = {
					if let download = DownloadManager.shared.getDownload(by: downloadId) {
						DownloadManager.shared.cancelDownload(download)
					}
					self.activeTasks.removeValue(forKey: task.identifier)
				}
			}
			self.registeredTasks.insert(taskIdentifier)
		}
		
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			print(error)
		}
	}
	
	func updateProgress(for downloadId: String, progress: Double) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		
		guard let task = activeTasks[taskIdentifier] else { return }
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(progress * 100)
		
		task.updateTitle(task.title, subtitle: "\(Int(progress * 100))%")
		
		if task.progress.completedUnitCount == task.progress.totalUnitCount {
			stopTask(for: downloadId, success: true)
		}
	}
	
	func stopTask(for downloadId: String, success: Bool) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		guard let task = activeTasks[taskIdentifier] else { return }
		
		task.setTaskCompleted(success: success)
		activeTasks.removeValue(forKey: taskIdentifier)
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif
