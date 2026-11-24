import SwiftUI

/// 主界面：只有实时字幕这一页。
///
/// 这个版本是给使用者自己接自己 API 用的工具版：
/// 没有账号、没有积分、没有内购、没有同声传译、没有历史记录，
/// 打开就是字幕，设置里只有两样：豆包凭据、字幕样式。
struct MainView: View {
    var body: some View {
        NavigationStack {
            HomeView()
                .navigationTitle("实时字幕")
                .navigationBarTitleDisplayMode(.inline)
        }
        // 画中画的锚点必须挂在最外层：锚点一离开窗口，系统就把浮窗收掉。
        // 系统录屏面板也放这里，首页的按钮只是"借"它的点击。
        .overlay(
            ZStack {
                PipAnchor().frame(width: 1, height: 1)
                BroadcastPicker().frame(width: 60, height: 60)
            }
            .opacity(0.01)
            .allowsHitTesting(false)
        )
    }
}
