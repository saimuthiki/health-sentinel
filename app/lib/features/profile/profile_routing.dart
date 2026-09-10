/// Where the health profile lives, and which of its two jobs is being asked for.
///
/// One screen was doing two quite different things, and that is the whole of the
/// bug the owner reported. Filling the profile in for the first time is a guided
/// sequence: one small question at a time, each with the reason it is being
/// asked next to it, because somebody who has just installed the app has no idea
/// why it wants their date of birth. Coming back to the profile from More is not
/// that job at all. It is "show me what you already told you, and let me change
/// the one thing I came here to change" - and being made to walk through six
/// steps of questions you have already answered, with every box empty again, is
/// how somebody decides the app has lost their details.
///
/// So there are two destinations rather than one screen in two moods.
///
/// [profileWizardPath] is the first run. It sits outside the tab shell because
/// during onboarding there are no tabs yet.
///
/// [profileReviewPath] is the way back in. It is a child of `/more`, exactly as
/// `/more/reminders` and `/more/export` are, and for the same reason: the tab
/// bar stays where it is, the More tab keeps its place in the stack, and going
/// back is going back to the list the tile was on. That is the "back option"
/// that was missing.
///
/// [profileReturnParam] is the third case, and it is the reason a query
/// parameter is here at all. The wizard can also be opened *from* the summary,
/// by somebody who skipped questions the first time and would rather be walked
/// through the lot again than hunt for the three they missed. It is the same
/// wizard, but it has to go back where it came from instead of dumping the
/// person on Today. Saying so in the URL is the pattern `?blocked=1` already
/// uses on the consent screen: the destination is one route, and what it needs
/// to know about how it was reached rides along beside it.
library;

/// The six-step first-run wizard.
const String profileWizardPath = '/profile';

/// Everything already saved, each answer editable on its own.
const String profileReviewPath = '/more/profile';

/// The query parameter that says where finishing the wizard should lead.
const String profileReturnParam = 'return';

/// The one value [profileReturnParam] takes: "back to the summary".
const String profileReturnReview = 'review';

/// The wizard, opened from the summary and returning to it.
const String profileWizardFromReviewPath =
    '$profileWizardPath?$profileReturnParam=$profileReturnReview';
