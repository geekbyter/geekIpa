//
//  VariedTabbarView.swift
//  geekIpa
//
//  三 Tab 框架（规格书 §1.1）：应用 / 证书 / 设备。
//  结构体名保持 VariedTabbarView 不变（geekIpaApp 根视图引用处不改）。
//

import SwiftUI

struct VariedTabbarView: View {
	init() {}
	
	@State private var _selectedTab: RootTab = .apps
	
	/// 根部三个固定 Tab（规格书 §1.1，图标与文案固定）
	enum RootTab: Hashable {
		case apps
		case certs
		case device
	}
	
	// MARK: Body
	var body: some View {
		TabView(selection: $_selectedTab) {
			// Tab 1：应用页（已导入 / 已签名 / 已安装），本任务提供
			NavigationStack {
				AppsView()
			}
			.tabItem { Label("应用", systemImage: "square.grid.2x2") }
			.tag(RootTab.apps)
			
			// CONTRACT: CertsView 由证书任务提供（无参 init，外层包 NavigationStack）
			NavigationStack {
				CertsView()
			}
			.tabItem { Label("证书", systemImage: "checkmark.shield") }
			.tag(RootTab.certs)
			
			// CONTRACT: DeviceView 由设备页任务提供（无参 init，外层包 NavigationStack；设置入口由设备页承担）
			NavigationStack {
				DeviceView()
			}
			.tabItem { Label("设备", systemImage: "iphone") }
			.tag(RootTab.device)
		}
		.tint(.geekPrimary)
		// TabView 默认保持各 Tab 视图状态（滚动位置 / 已选分段 / 表单草稿不重置）
	}
}
