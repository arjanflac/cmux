public import CmuxHomeCore
public import Foundation

/// Everything a ``ChiefBrain`` needs to run one turn.
public struct ChiefTurnRequest: Sendable {
    /// The conversation the turn answers in.
    public var conversation: ConversationID
    /// The CLI session id the previous turn reported (``ChiefTurnEvent/session(_:)``),
    /// nil for the conversation's first turn.
    public var resumeSession: String?
    /// The user's message, with a note for each attached non-image file.
    public var userText: String
    /// Image attachments as local files the brain can pass to the model.
    public var attachmentPaths: [URL]
    /// What the user replies to (a thread root's text), nil for a plain message.
    public var replyContext: String?
    /// The Chief's system prompt from the app's ``ChiefTurnContextProvider``.
    public var systemPrompt: String
    /// The directory the brain's process runs in.
    public var workingDirectory: URL
    /// Extra environment for the brain's process.
    public var environment: [String: String]
    /// A durable identity for this prompt, nil to let the brain pick a random one.
    ///
    /// Managed task turns pass their operation ID so the provider's echo of the
    /// prompt correlates with a saved receipt. It is correlation, not deduplication.
    public var promptID: UUID?

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - conversation: The conversation the turn answers in.
    ///   - resumeSession: The CLI session to resume, if any.
    ///   - userText: The user's message.
    ///   - attachmentPaths: Image files for the model.
    ///   - replyContext: What the message replies to, if anything.
    ///   - systemPrompt: The Chief's system prompt.
    ///   - workingDirectory: The process's working directory.
    ///   - environment: Extra process environment.
    ///   - promptID: A durable prompt identity; nil (the default) keeps the brain's random one.
    public init(conversation: ConversationID, resumeSession: String?, userText: String, attachmentPaths: [URL],
                replyContext: String?, systemPrompt: String, workingDirectory: URL, environment: [String: String],
                promptID: UUID? = nil) {
        self.conversation = conversation
        self.resumeSession = resumeSession
        self.userText = userText
        self.attachmentPaths = attachmentPaths
        self.replyContext = replyContext
        self.systemPrompt = systemPrompt
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.promptID = promptID
    }
}
