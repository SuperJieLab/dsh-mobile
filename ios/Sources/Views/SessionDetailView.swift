import SwiftUI

/// 单个会话的消息视图。
///
/// 数据来自 `SessionSync` —— 它负责「先取一个窗口、再往后追新增、按需往回翻」，
/// 这个屏只负责画出来，以及把同步状态如实显示在底部。
///
/// **往回翻是显式的**（列表第一行那个入口）：历史只在用户要的时候才拉，而不是偷偷
/// 多拉一批。`hasOlder` 由服务端给，客户端不自己猜还有没有。
///
/// 其余事件（工具调用、轮次边界、用量、审批……）不进对话流 ——
/// 它们属于「过程」，而这个屏要回答的是「这个会话聊了什么」。
struct SessionDetailView: View {
    let client: GatewayClient
    let session: SessionSummary

    /// 同步编排。视图重建时会新建一个，于是窗口重取一次 —— 这是刻意的：
    /// 窗口是服务端此刻给的，比任何本地残留都可信（见 `SessionMirror` 的说明）。
    @StateObject private var sync: SessionSync

    /// 是否已经做过「首次定位到最新」。之后的内容变化（往回翻的前插）不再抢视口。
    @State private var didInitialScroll = false

    init(client: GatewayClient, session: SessionSummary) {
        self.client = client
        self.session = session
        _sync = StateObject(wrappedValue: SessionSync(client: client, sessionId: session.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if sync.hasOlder {
                    Button {
                        Task { await sync.loadOlder() }
                    } label: {
                        HStack {
                            Spacer()
                            if sync.status == .syncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("加载更早的消息")
                            }
                            Spacer()
                        }
                    }
                    .disabled(sync.status == .syncing)
                    .listRowSeparator(.hidden)
                }

                if sync.eventCount > 0 && sync.messages.isEmpty {
                    Text("这个会话里没有可显示的消息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(sync.messages) { message in
                    MessageBubble(message: message)
                }

                // 滚动锚点：初始同步完成后定位到这里（最新的消息在列表末尾）。
                Color.clear
                    .frame(height: 1)
                    .listRowSeparator(.hidden)
                    .id(Self.bottomAnchor)

                Section {
                    EmptyView()
                } footer: {
                    Text("共 \(sync.eventCount) 条事件，其中 \(sync.messages.count) 条消息 · \(sync.status.line)")
                }
            }
            .listStyle(.plain)
            // 打开会话 = 停在最新的消息上（对话的阅读方向），而不是列表的开头。
            .defaultScrollAnchor(.bottom)
            .onChange(of: sync.messages.count) { _, count in
                // 只在**首次**有内容时滚一次：往回翻（前插）不能把用户的视口拽走。
                guard !didInitialScroll, count > 0 else { return }
                didInitialScroll = true
                withAnimation {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .overlay {
                if sync.status == .idle && sync.eventCount == 0 {
                    ProgressView("正在同步…")
                }
            }
            .refreshable { await sync.sync() }
            .task { await sync.sync() }
        }
    }

    /// 底部滚动锚点的 id。`private` 的静态值即可 —— 只有这个视图需要它。
    private static let bottomAnchor = "session-detail-bottom"
}

/// 一条消息气泡。
private struct MessageBubble: View {
    let message: DisplayMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? "你" : "DSH")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isUser ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 14)
                )
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
    }
}
