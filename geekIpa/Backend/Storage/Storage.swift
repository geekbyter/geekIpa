//
//  Persistence.swift
//  geekIpa
//
//  Created by samara on 10.04.2025.
//

import CoreData
import Foundation

// MARK: - Storage
final class Storage: ObservableObject {
	static let shared = Storage()
	let container: NSPersistentContainer
	
	private let _name: String = "geekIpa"

	init(inMemory: Bool = false) {
		container = NSPersistentContainer(name: _name)

		if inMemory {
			container.persistentStoreDescriptions.first?.url =
				URL(fileURLWithPath: "/dev/null")
		}
		
		container.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically = true
		container.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically = true

		_loadPersistentStoreAggressively()
		container.viewContext.automaticallyMergesChangesFromParent = true
		container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
	}

	var context: NSManagedObjectContext {
		container.viewContext
	}
	
	func saveContext() {
		DispatchQueue.main.async {
			if self.context.hasChanges {
				try? self.context.save()
			}
		}
	}
	
	

	/// 同步加载持久化存储：
	/// 1) 正常加载（含轻量迁移）
	/// 2) 失败 → 清理损坏库后重试
	/// 3) 仍失败 → 退回内存库，保证 App 一定能启动（不 fatalError）
	private func _loadPersistentStoreAggressively() {
		let coordinator = container.persistentStoreCoordinator
		let storeURL = NSPersistentContainer.defaultDirectoryURL()
			.appendingPathComponent("\(_name).sqlite")
		let options: [AnyHashable: Any] = [
			NSMigratePersistentStoresAutomaticallyOption: true,
			NSInferMappingModelAutomaticallyOption: true
		]

		do {
			try coordinator.addPersistentStore(
				ofType: NSSQLiteStoreType,
				configurationName: nil,
				at: storeURL,
				options: options
			)
			return
		} catch {
			NSLog("[Storage] 首次加载失败，尝试清理后重试: %@", String(describing: error))
		}

		_destroyStore(at: storeURL)

		do {
			try coordinator.addPersistentStore(
				ofType: NSSQLiteStoreType,
				configurationName: nil,
				at: storeURL,
				options: options
			)
			return
		} catch {
			NSLog("[Storage] 重试仍失败，回退内存库: %@", String(describing: error))
		}

		do {
			try coordinator.addPersistentStore(
				ofType: NSInMemoryStoreType,
				configurationName: nil,
				at: nil,
				options: nil
			)
		} catch {
			NSLog("[Storage] 内存库也失败（极端情况，不再崩溃）: %@", String(describing: error))
		}
	}

	private func _destroyStore(at url: URL?) {
		guard let url else { return }

		let base = url.deletingPathExtension()
		let fm = FileManager.default

		let files = [
			base.appendingPathExtension("sqlite"),
			base.appendingPathExtension("sqlite-wal"),
			base.appendingPathExtension("sqlite-shm")
		]

		for file in files {
			try? fm.removeItem(at: file)
		}
		
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.signed)
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.unsigned)
		try? FileManager.default.removeFileIfNeeded(at: FileManager.default.certificates)
		UserDefaults.standard.set(0, forKey: "geekIpa.selectedCert")
	}
}
