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

  // ------------------------------------------------------------------- ocr

  /// A page whose text layer has fewer non-space characters than this is not
  /// a real text page and is recognized with OCR. Reasoning: a page of
  /// questions has several hundred characters (a generated six question page
  /// about 500); a page that is a scanned or exported image typically keeps
  /// only a watermark or a footer (a 41 character watermark was measured on a
  /// real test). 120 sits well between the two. A page that already yields
  /// questions or a key from its text layer is never recognized.
  static const ocrMinTextLayerChars = 120;

  /// Pages are rendered at this multiple of their size in points (72 dpi) for
  /// OCR, so the small print of a footer key (about 6 pt) is still about 18
  /// pixels high.
  static const ocrRenderScale = 3.0;

  /// The OCR render is scaled down so that it has at most this many pixels.
  static const ocrMaxPixels = 12000000;

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

  /// A line is a key line when at least this fraction of its tokens belong to
  /// `number letter` entries (so a page number beside the key does not hide
  /// it) and it holds at least two entries.
  static const footerKeyLineCoverage = 0.8;

  // ------------------------------------------------------------------- ink

  /// Only strokes drawn with these tools are graded. The highlighter is
  /// ignored on purpose.
  static const Set<ToolId> gradableTools = {
    ToolId.fountainPen,
    ToolId.ballpointPen,
    ToolId.pencil,
    ToolId.shapePen,
  };

  /// PDF annotations (Ink, Polygon, ...) with a lower opacity (/CA) than this
  /// are highlighter strokes and ignored, like Saber's highlighter. Flexcil's
  /// translucent pens are around 0.3 to 0.5, ink pens 1.0.
  static const annotationMinOpacity = 0.9;

  /// Width in PDF points assumed for an annotation without a readable border
  /// width.
  static const double annotationDefaultWidthPts = 1;

  /// The thin outline made from an annotation's centre line is at least this
  /// wide (note units): Saber's thinnest pen outline is about this.
  static const annotationMinOutlineWidth = 1.5;

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

  /// A tick this close (horizontally) to the label or option text scores
  /// full marks ...
  static const double tickNearDistance = 25;

  /// ... and scores less the further away it is, down to nothing at this
  /// distance.
  static const double tickMaxDistance = 50;

  /// A tick must be at least this large (larger side of the stroke bounds).
  /// Smaller strokes beside a label are dots (pen rests, taps) and score 0.
  /// Measured with real strokes: a 1-3 point tap is 2.6, 5.6 and 9.6 units
  /// for pen sizes 2, 5 and 9; the smallest tick fixture (label 12 high) is
  /// 12.8.
  static const double tickMinSize = 11;

  /// Score of a tick at its best (a ring or a filled bubble scores up to 1).
  static const tickScore = 0.85;

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

  /// Every constant by name, for the grading report.
  static Map<String, Object> get all => {
    'rowOverlapFraction': rowOverlapFraction,
    'tokenGapFraction': tokenGapFraction,
    'columnSeparationFraction': columnSeparationFraction,
    'columnTolerancePts': columnTolerancePts,
    'inlineOptionGapFraction': inlineOptionGapFraction,
    'minOptionsPerQuestion': minOptionsPerQuestion,
    'maxQuestionNumber': maxQuestionNumber,
    'maxQuestionNumberSkip': maxQuestionNumberSkip,
    'optionContinuationGapFraction': optionContinuationGapFraction,
    'keyMinConsecutiveRun': keyMinConsecutiveRun,
    'keyMinCoverage': keyMinCoverage,
    'keyAcceptConfidence': keyAcceptConfidence,
    'keyMinQuestionCoverage': keyMinQuestionCoverage,
    'footerKeyLineCoverage': footerKeyLineCoverage,
    'ocrMinTextLayerChars': ocrMinTextLayerChars,
    'ocrRenderScale': ocrRenderScale,
    'ocrMaxPixels': ocrMaxPixels,
    'annotationMinOpacity': annotationMinOpacity,
    'annotationDefaultWidthPts': annotationDefaultWidthPts,
    'annotationMinOutlineWidth': annotationMinOutlineWidth,
    'gradableTools': gradableTools,
    'resampleStep': resampleStep,
    'regionInflate': regionInflate,
    'strayDistance': strayDistance,
    'ringMinCoverage': ringMinCoverage,
    'ringSectors': ringSectors,
    'ringMinRadiusFraction': ringMinRadiusFraction,
    'ringMaxInnerFraction': ringMaxInnerFraction,
    'labelInflate': labelInflate,
    'fillMinFraction': fillMinFraction,
    'tickNearDistance': tickNearDistance,
    'tickMaxDistance': tickMaxDistance,
    'tickMinSize': tickMinSize,
    'tickScore': tickScore,
    'compactMaxSize': compactMaxSize,
    'lineMaxElongation': lineMaxElongation,
    'lineMinLength': lineMinLength,
    'lineMaxAngleDegrees': lineMaxAngleDegrees,
    'strikeMinCoverage': strikeMinCoverage,
    'strikeBandTop': strikeBandTop,
    'strikeBandBottom': strikeBandBottom,
    'underlineBandBottom': underlineBandBottom,
    'underlineScore': underlineScore,
    'crossMinHeightFraction': crossMinHeightFraction,
    'markThreshold': markThreshold,
    'decisionMargin': decisionMargin,
    'highConfidenceScore': highConfidenceScore,
    'highConfidenceMargin': highConfidenceMargin,
  };
}
