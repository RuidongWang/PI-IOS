import Foundation

/// 点击发送时冻结的发送意图（U11）。
///
/// 发送按钮拿到点击后还要先做一次模型可用性检查（可能等待网络）。等待期间用户可能
/// 切换服务器/会话、改选模型或继续编辑草稿；若发送任务直接读取「当前状态」，
/// 就可能把 B 会话的草稿当成 A 的点击发出去。因此点击时冻结这里全部字段，
/// 进入发送与真正提交前都用它核对当前状态仍属于原意图。
public struct SendIntent: Equatable, Sendable {
    /// PI-adaptor 身份（`session/attach` 之后由 `client.info()` 得到），不是本机 HostRecord UUID。
    public let hostID: String
    public let sessionID: String
    /// 模型绑定维度：provider + model + thinking 档位。
    public let bindingKey: String
    /// 点击时已 trim 的草稿正文。
    public let draftText: String
    /// 点击时待发送区的附件 id（服务端 `attachment/upload` 返回的 id）。
    public let attachmentIDs: [String]
    /// 附件所属会话代次：切换会话后递增，防止旧意图匹配到新会话的同名附件。
    public let selectionGeneration: Int

    public init(
        hostID: String,
        sessionID: String,
        bindingKey: String,
        draftText: String,
        attachmentIDs: [String],
        selectionGeneration: Int
    ) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.bindingKey = bindingKey
        self.draftText = draftText
        self.attachmentIDs = attachmentIDs
        self.selectionGeneration = selectionGeneration
    }

    /// 当前状态是否仍与冻结意图一致。附件 id 顺序不参与比较。
    public func matches(
        hostID: String,
        sessionID: String,
        bindingKey: String,
        draftText: String,
        attachmentIDs: [String],
        selectionGeneration: Int
    ) -> Bool {
        self.hostID == hostID
            && self.sessionID == sessionID
            && self.bindingKey == bindingKey
            && self.draftText == draftText
            && self.attachmentIDs.sorted() == attachmentIDs.sorted()
            && self.selectionGeneration == selectionGeneration
    }

    /// 是否仍指向同一台服务器上的同一个会话（与草稿内容无关）。
    public func isSameSession(hostID: String, sessionID: String) -> Bool {
        self.hostID == hostID && self.sessionID == sessionID
    }
}
