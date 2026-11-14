import 'package:sbn/tool_id.dart';

/// Every tunable number of the grader, in one place.
///
/// Lengths named `...Pts` are PDF points (1/72 inch, in the PDF's visual
/// space). All other lengths are note-page units (a PDF page is 1000 units
/// wide once imported). Fractions and factors are unitless.
abstract final class GradingConfig {
  // ---------------------------------------------------------------- layout

  /// Two characters on the same row if their vertical extents overlap by at
  /// least this fraction of the smaller one.
  static const rowOverlapFraction = 0.5;

  /// A horizontal gap larger than this fraction of the row height starts a
  /// new token (word) even without a space character in the text layer.
  static const tokenGapFraction = 0.5;

  /// Question numbers whose left edges are further apart than this fraction
  /// of the page width belong to different columns.
  static const columnSeparationFraction = 0.25;

  /// Left edges of question numbers closer than this belong to one column
  /// (absorbs right-aligned numbers such as `9.` and `10.`).
  static const double columnTolerancePts = 20;

  /// An option label that does not start its line must be preceded by a gap of
  /// at least this fraction of the line height (inline options).
  static const inlineOptionGapFraction = 0.5;

  /// A question needs at least this many options (A, B, ...) in sequence to
  /// be located; anything else is treated as ordinary text.
  static const minOptionsPerQuestion = 2;

  /// Largest accepted question number.
  static const maxQuestionNumber = 300;

  /// A question number may skip at most this many numbers (a missed question)
  /// relative to the previous one; otherwise it is treated as text.
  static const maxQuestionNumberSkip = 3;

  /// A line directly under an option (gap below this fraction of the line
  /// height) that is not a label or number continues that option's text.
  static const optionContinuationGapFraction = 0.8;

  // ------------------------------------------------------------------- key

  /// A key page needs a run of at least this many consecutive question
  /// numbers, each followed by a letter.
  static const keyMinConsecutiveRun = 5;

  /// A key page needs at least this fraction of its tokens to belong to
  /// `number letter` entries (a page of questions has far less).
  static const keyMinCoverage = 0.5;

  /// The key is accepted ("found") only if the weakest key page has at least
  /// this coverage; below it the status is `unknown` and the UI should ask.
  static const keyAcceptConfidence = 0.75;

  /// At least this fraction of a test's question numbers must have an entry
  /// in the key block paired with it, otherwise the pairing is rejected.
  static const keyMinQuestionCoverage = 0.5;

  // ------------------------------------------------------------------- ink

  /// Only strokes drawn with these tools are graded. The highlighter is
  /// ignored on purpose.
  static const Set<ToolId> gradableTools = {
    ToolId.fountainPen,
    ToolId.ballpointPen,
    ToolId.pencil,
    ToolId.shapePen,
  };

  /// Stroke outlines are resampled so that no two neighbouring points are
  /// further apart than this.
  static const double resampleStep = 3;

  /// Question regions are inflated by this much when counting which stroke
  /// points lie in them.
  static const double regionInflate = 24;

  /// A stroke further than this from every question region is a stray mark
  /// and ignored.
  static const double strayDistance = 60;

  /// Rings: at least this fraction of 16 angular sectors around the label
  /// centre must contain stroke points.
  static const ringMinCoverage = 0.8;

  /// Number of angular sectors used for the surround test.
  static const ringSectors = 16;

  /// Ring points must lie at least this fraction of the label's shorter side
  /// away from the label centre to count for a sector.
  static const ringMinRadiusFraction = 0.5;

  /// A ring has at most this fraction of its points inside the label (else
  /// it is a filled scribble, not a circle).
  static const ringMaxInnerFraction = 0.15;

  /// Label rectangles are inflated by this much for "ink on the label".
  static const double labelInflate = 3;

  /// At least this fraction of points inside the label: a filled bubble.
  static const fillMinFraction = 0.3;

  /// A tick may be at most this far (horizontally) from the label.
  static const double tickMaxDistance = 40;

  /// A compact mark (tick, bubble) is at most this large in either direction.
  static const double compactMaxSize = 120;

  /// Elongation (minor/major standard deviation) below which a stroke is a
  /// straight line.
  static const lineMaxElongation = 0.2;

  /// A line stroke must be at least this long.
  static const double lineMinLength = 20;

  /// Line strokes within this angle (degrees) of horizontal are strikes or
  /// underlines; steeper ones are diagonals (candidates for an X).
  static const double lineMaxAngleDegrees = 30;

  /// A strike must cover at least this fraction of the option box width.
  static const strikeMinCoverage = 0.6;

  /// Vertical position of a horizontal line inside the option box, as a
  /// fraction of its height from the top. Within [strikeBandTop,
  /// strikeBandBottom] it is a strike-through, below it (up to
  /// [underlineBandBottom]) an underline.
  static const strikeBandTop = 0.2;
  static const strikeBandBottom = 0.72;
  static const underlineBandBottom = 1.6;

  /// Score of an underline (a weaker mark than a ring).
  static const underlineScore = 0.75;

  /// A diagonal of an X must cover at least this fraction of the box height.
  static const crossMinHeightFraction = 0.5;

  /// An option needs at least this score to count as marked.
  static const markThreshold = 0.4;

  /// The best option must beat the runner-up by at least this much.
  static const decisionMargin = 0.25;

  /// Score and margin for high confidence.
  static const highConfidenceScore = 0.9;
  static const highConfidenceMargin = 0.5;
}
