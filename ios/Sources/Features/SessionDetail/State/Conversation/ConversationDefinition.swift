/**
 * 定义与引擎之间的唯一接口 —— 每个 kind 只回答四件事：
 * 哪些事件归我、我怎么变、我什么时候发布、我长什么样。
 *
 * 定义不认识别的定义、不认识事件窗口、也不认识渲染层；引擎不认识任何业务词汇。
 * 类型擦除（`AnyNodeDefinition`）放在这里而不是定义文件里：新增一个 kind 不该让别的定义重新编译。
 */
import Foundation

enum MatchRole: Equatable {
    /// 建立这个槽位的那条事件。同一个槽位只认窗口里最早的那条。
    case start
    /// 之后所有命中，包括迟到的第二条 start。
    case update
}

struct MatchResult: Equatable {
    let id: String
    let role: MatchRole
}

/// 一条被接受的事件：事件本身 + 它的生命周期角色 + 解析出的位置。
struct ConversationMatch: Equatable {
    let event: AssemblyEvent
    let role: MatchRole
    let location: ConversationLocation
}

/// 发布节奏。`animationFrame` 表示「同一帧内多次变化只发布一次」，由驱动方合并。
enum Publication: Int, Comparable {
    case none = 0
    case animationFrame = 1
    case immediate = 2

    static func < (left: Publication, right: Publication) -> Bool {
        left.rawValue < right.rawValue
    }

    static func maximum(_ left: Publication, _ right: Publication) -> Publication {
        left >= right ? left : right
    }
}

/// 定义看到的一份只读上下文。
struct NodeContext<State> {
    let key: String
    let kind: String
    let id: String
    let matches: [ConversationMatch]
    let start: ConversationMatch?
    let state: State?
    /// 上一次物化出来的节点。定义要靠它决定「转 hidden」还是「照常返回」。
    let current: ChatNode?
}

protocol ConversationNodeDefinition {
    associatedtype State

    var kind: String { get }

    func match(_ event: AssemblyEvent) -> MatchResult?
    func start(_ context: NodeContext<State>, _ match: ConversationMatch) -> State
    func update(_ context: NodeContext<State>, _ match: ConversationMatch) -> State
    func publication(_ match: ConversationMatch) -> Publication
    func buildViewNode(_ context: NodeContext<State>) -> ChatNode?
}

extension ConversationNodeDefinition {
    /// 默认「立刻发布」：结构变化都该立刻可见；高频增量自己覆盖成 `animationFrame`。
    func publication(_ match: ConversationMatch) -> Publication { .immediate }
}

/// 擦掉 `State` 之后的定义 —— 引擎表里装的是它。
struct AnyNodeDefinition {
    let kind: String

    private let matchFunction: (AssemblyEvent) -> MatchResult?
    private let startFunction: (NodeContext<Any>, ConversationMatch) -> Any
    private let updateFunction: (NodeContext<Any>, ConversationMatch) -> Any
    private let publicationFunction: (ConversationMatch) -> Publication
    private let buildFunction: (NodeContext<Any>) -> ChatNode?

    init<Definition: ConversationNodeDefinition>(_ definition: Definition) {
        kind = definition.kind
        matchFunction = { definition.match($0) }
        startFunction = { context, match in
            definition.start(context.typed(Definition.State.self), match)
        }
        updateFunction = { context, match in
            definition.update(context.typed(Definition.State.self), match)
        }
        publicationFunction = { definition.publication($0) }
        buildFunction = { definition.buildViewNode($0.typed(Definition.State.self)) }
    }

    func match(_ event: AssemblyEvent) -> MatchResult? { matchFunction(event) }
    func start(_ context: NodeContext<Any>, _ match: ConversationMatch) -> Any { startFunction(context, match) }
    func update(_ context: NodeContext<Any>, _ match: ConversationMatch) -> Any { updateFunction(context, match) }
    func publication(_ match: ConversationMatch) -> Publication { publicationFunction(match) }
    func buildViewNode(_ context: NodeContext<Any>) -> ChatNode? { buildFunction(context) }
}

extension NodeContext where State == Any {
    /// 把擦掉的状态装回去。装不回去只有一个原因：定义换了而格子没重建 —— 那属于引擎的错。
    func typed<Value>(_ type: Value.Type) -> NodeContext<Value> {
        NodeContext<Value>(
            key: key,
            kind: kind,
            id: id,
            matches: matches,
            start: start,
            state: state as? Value,
            current: current
        )
    }
}

/// 格子键。带长度前缀，避免 `kind` 与 `id` 拼接后撞车（`a` + `bc` 与 `ab` + `c`）。
func conversationContextKey(kind: String, id: String) -> String {
    "\(kind.count):\(kind)\(id)"
}
