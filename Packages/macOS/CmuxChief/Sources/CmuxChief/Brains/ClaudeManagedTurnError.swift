import Foundation

/// Why a managed-mode Claude Code turn ended without a provider result.
///
/// Thrown from a ``ClaudeCodeBrain`` turn stream only when its configuration
/// sets ``ClaudeCodeBrain/Configuration/managedConversation``. Each case states
/// what is known about the prompt, so a caller never mistakes uncertainty
/// for success or a missing conversation for a new one.
enum ClaudeManagedTurnError: Error, Equatable, Sendable {
    /// Another turn of this conversation is still running; nothing was sent.
    case busy
    /// The prompt was never written (launch, resume or `initialize` failed).
    case notSent(String)
    /// The prompt may have reached Claude Code but no result was observed.
    case unconfirmed(String)
    /// Claude Code reported that the turn was interrupted.
    case interrupted
    /// Claude Code reported a different session than the one requested.
    case sessionChanged(String)
    /// The permission request is no longer pending in the live process.
    case staleRequest
}
