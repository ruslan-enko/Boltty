import AppKit
import XCTest
@testable import Boltty

@MainActor
final class PaletteGlassHostTests: XCTestCase {
  func testDefaultHostDoesNotEnableDirectionalOverlay() {
    let host = PaletteGlassHost(content: NSView(), cornerRadius: 24)

    XCTAssertFalse(host.hasVerticalOverlayForTesting)
    XCTAssertEqual(host.glassMaterialStyleForTesting, .regular)
  }

  func testGlassIsNotInteractiveByDefault() {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 43,
      style: .bolttyAI
    )
    XCTAssertFalse(host.effectIsInteractive)
  }

  func testSurfaceStyleMaterialIsRetained() {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 28,
      style: PaletteSurfaceStyle(material: .clear)
    )

    XCTAssertEqual(host.glassMaterialStyleForTesting, .clear)
  }

  func testThePromptCapsuleWearsADenseResampledRamp() throws {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 43,
      style: .bolttyAIPrompt
    )
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 540, height: 85)
    host.apply(showsGlass: true)
    host.layoutSubtreeIfNeeded()

    let colors = host.verticalOverlayColorsForTesting
    let locations = host.verticalOverlayLocationsForTesting

    XCTAssertEqual(colors.count, PaletteGlassRamp.resolution)
    XCTAssertEqual(locations.count, PaletteGlassRamp.resolution)
    XCTAssertEqual(locations.first ?? -1, 0, accuracy: 0.001)
    XCTAssertEqual(locations.last ?? -1, 1, accuracy: 0.001)

    for (index, location) in locations.enumerated() {
      let expected = CGFloat(index) / CGFloat(PaletteGlassRamp.resolution - 1)
      XCTAssertEqual(location, expected, accuracy: 0.001)
    }

    let alphas = try colors.map {
      try XCTUnwrap(NSColor(cgColor: $0)?.usingColorSpace(.sRGB)).alphaComponent
    }
    for (previous, next) in zip(alphas, alphas.dropFirst()) {
      XCTAssertGreaterThanOrEqual(previous, next - 0.0001)
    }
    XCTAssertGreaterThan(try XCTUnwrap(alphas.first), try XCTUnwrap(alphas.last))

    XCTAssertFalse(host.usesSoftLightWashForTesting)
    XCTAssertTrue(host.isVerticalOverlayBelowContentForTesting)
    XCTAssertTrue(host.isVerticalOverlayInFrontOfGlassForTesting)
  }

  func testBolttyAIDrawsNoScreenBlendedFootLift() {
    for style in [PaletteSurfaceStyle.bolttyAI, .bolttyAIPrompt] {
      let host = PaletteGlassHost(
        content: NSView(),
        cornerRadius: 28,
        style: style
      )
      host.frame = NSRect(x: 0, y: 0, width: 520, height: 56)
      host.apply(showsGlass: true)
      host.layoutSubtreeIfNeeded()

      XCTAssertTrue(host.isBottomHighlightHiddenForTesting)
      XCTAssertFalse(host.usesBottomHighlightScreenBlendForTesting)
    }
  }

  func testThePromptRampRunsFromABlackCrownToNothingAtTheFoot() throws {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 43,
      style: .bolttyAIPrompt
    )
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 540, height: 85)
    host.apply(showsGlass: true)
    host.layoutSubtreeIfNeeded()

    let colors = host.verticalOverlayColorsForTesting
    let crown = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(colors.first))?.usingColorSpace(.sRGB))
    let foot = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(colors.last))?.usingColorSpace(.sRGB))

    XCTAssertEqual(crown.redComponent, 0, accuracy: 0.005)
    XCTAssertEqual(crown.greenComponent, 0, accuracy: 0.005)
    XCTAssertEqual(crown.blueComponent, 0, accuracy: 0.005)
    XCTAssertEqual(crown.alphaComponent, 1, accuracy: 0.005)
    XCTAssertEqual(foot.alphaComponent, 0, accuracy: 0.01, "the glass alone at the foot")

    XCTAssertEqual(foot.alphaComponent, 0, accuracy: 0.01, "0% at the foot")

    XCTAssertEqual(host.effectiveGlassTintAlpha, 0, accuracy: 0.001)
    XCTAssertEqual(host.glassTintAlphaForTesting, 0, accuracy: 0.001)
    let composite = 1 - (1 - foot.alphaComponent) * (1 - host.effectiveGlassTintAlpha)
    XCTAssertEqual(composite, 0, accuracy: 0.01, "at the foot it is the bare glass")
  }

  func testGlassTintBelongsToTheOverlayNotTheHost() throws {
    func host(for style: PaletteSurfaceStyle) -> PaletteGlassHost {
      let host = PaletteGlassHost(
        content: NSView(),
        cornerRadius: 43,
        style: style
      )
      host.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
      host.apply(showsGlass: true)
      host.layoutSubtreeIfNeeded()
      return host
    }
    let silentWash = PaletteGlassVerticalOverlay.multiStop([
      .srgb(0, 0, 0, alpha: 0.5, at: 0),
      .srgb(0, 0, 0, alpha: 0.5, at: 1),
    ])

    let stated = host(for: PaletteSurfaceStyle(material: .regular, wash: .bolttyAIPromptRamp))
    XCTAssertEqual(stated.effectiveGlassTintAlpha, 0, accuracy: 0.001)
    XCTAssertNotEqual(
      stated.effectiveGlassTintAlpha,
      PaletteGlassHost.defaultGlassTintAlpha,
      accuracy: 0.001
    )

    let shell = host(for: .bolttyAI)
    XCTAssertEqual(shell.effectiveGlassTintAlpha, 0, accuracy: 0.001)
    XCTAssertEqual(shell.glassTintAlphaForTesting, 0, accuracy: 0.001)

    let both = host(for: PaletteSurfaceStyle(
      material: .regular, wash: .bolttyAIPromptRamp, glassTintAlpha: 0.3))
    XCTAssertEqual(both.effectiveGlassTintAlpha, 0, accuracy: 0.001)
    let styled = host(for: PaletteSurfaceStyle(
      material: .regular, wash: silentWash, glassTintAlpha: 0.3))
    XCTAssertEqual(styled.effectiveGlassTintAlpha, 0.3, accuracy: 0.001)

    let silent = host(for: PaletteSurfaceStyle(material: .regular, wash: silentWash))
    XCTAssertEqual(silent.effectiveGlassTintAlpha, PaletteGlassHost.defaultGlassTintAlpha)

    let plain = host(for: PaletteSurfaceStyle(material: .regular))
    XCTAssertEqual(plain.effectiveGlassTintAlpha, PaletteGlassHost.defaultGlassTintAlpha)
  }

  func testReducedTransparencyFallbackIsDenserThanTheGlassWash() throws {
    let overlay = PaletteGlassVerticalOverlay.bolttyAIPromptRamp
    let glass = overlay.stops(reduceTransparency: false)
    let opaque = overlay.stops(reduceTransparency: true)
    XCTAssertEqual(opaque.count, PaletteGlassRamp.resolution)

    XCTAssertEqual(glass.count, opaque.count)
    for (glassStop, opaqueStop) in zip(glass, opaque) {
      let glassAlpha = glassStop.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0
      let opaqueAlpha = opaqueStop.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0
      XCTAssertGreaterThanOrEqual(
        opaqueAlpha,
        glassAlpha,
        "Reduce Transparency must never be the more see-through of the two"
      )
    }

    for stop in opaque {
      let alpha = stop.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0
      XCTAssertGreaterThanOrEqual(
        alpha,
        0.65,
        "every fallback stop must hide a light backdrop"
      )
    }
  }

  func testCollinearControlPointsResampleToAStraightLine() throws {
    let ramp = PaletteGlassRamp.resample([
      .srgb(0, 0, 0, alpha: 1, at: 0),
      .srgb(0, 0, 0, alpha: 0.5, at: 0.5),
      .srgb(0, 0, 0, alpha: 0, at: 1),
    ])

    for stop in ramp {
      let alpha = stop.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0
      XCTAssertEqual(
        alpha,
        1 - stop.location,
        accuracy: 0.01,
        "a ramp through collinear stops must not scallop between them"
      )
    }
  }

  func testCapsuleRampSlopeNeverStalls() throws {
    let alphas = PaletteGlassVerticalOverlay.bolttyAIPromptRamp
      .stops(reduceTransparency: false)
      .map { $0.color.usingColorSpace(.sRGB)?.alphaComponent ?? 0 }
    let deltas = zip(alphas, alphas.dropFirst()).map { abs($1 - $0) }

    let mean = deltas.reduce(0, +) / CGFloat(deltas.count)
    let smallest = try XCTUnwrap(deltas.min())
    let largest = try XCTUnwrap(deltas.max())

    XCTAssertGreaterThan(
      smallest,
      mean * 0.35,
      "a step this flat means the curve braked at a control point"
    )
    XCTAssertLessThan(largest, mean * 2.0)
  }

  func testAdaptiveMonochromeOverlayFollowsAppearance() throws {
    let lightHost = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 28,
      style: PaletteSurfaceStyle(
        material: .regular,
        wash: PaletteGlassVerticalOverlay(bottomOpacity: 0.55)
      )
    )
    lightHost.appearance = NSAppearance(named: .aqua)
    lightHost.frame = NSRect(x: 0, y: 0, width: 520, height: 86)
    lightHost.layoutSubtreeIfNeeded()

    let lightBottom = try XCTUnwrap(
      NSColor(cgColor: lightHost.verticalOverlayColorsForTesting[1])?.usingColorSpace(.deviceRGB)
    )
    XCTAssertEqual(lightBottom.redComponent, 0, accuracy: 0.001)
    XCTAssertEqual(lightBottom.alphaComponent, 0.55, accuracy: 0.001)

    let darkHost = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 28,
      style: PaletteSurfaceStyle(
        material: .regular,
        wash: PaletteGlassVerticalOverlay(bottomOpacity: 0.55)
      )
    )
    darkHost.appearance = NSAppearance(named: .darkAqua)
    darkHost.frame = lightHost.frame
    darkHost.layoutSubtreeIfNeeded()

    let darkBottom = try XCTUnwrap(
      NSColor(cgColor: darkHost.verticalOverlayColorsForTesting[1])?.usingColorSpace(.deviceRGB)
    )
    XCTAssertEqual(darkBottom.redComponent, 0, accuracy: 0.001)
    XCTAssertEqual(darkBottom.alphaComponent, 0.55, accuracy: 0.001)
  }

  func testDirectionalOverlayCompositesInFrontOfGlassMaterial() {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 43,
      style: .bolttyAIPrompt
    )
    host.apply(showsGlass: true)
    host.frame = NSRect(x: 0, y: 0, width: 540, height: 85)
    host.layoutSubtreeIfNeeded()

    XCTAssertTrue(host.isVerticalOverlayInFrontOfGlassForTesting)
    XCTAssertTrue(host.isVerticalOverlayBelowContentForTesting)
    XCTAssertTrue(host.hasVerticalOverlayForTesting)
  }

  func testEveryBolttyAISurfaceButThePromptIsTheBareGlass() throws {
    XCTAssertEqual(PaletteSurfaceStyle.bolttyAIControl, .bolttyAI)
    XCTAssertEqual(PaletteSurfaceStyle.bolttyAIComposer, .bolttyAI)

    for (cornerRadius, height) in [
      (AgentPaletteMetrics.cornerRadius, CGFloat(98)),
      (AgentPaletteMetrics.cardCornerRadius, 300),
      (AgentPaletteMetrics.cardCornerRadius, 220),
    ] {
      let host = PaletteGlassHost(
        content: NSView(),
        cornerRadius: cornerRadius,
        style: .bolttyAI
      )
      host.appearance = NSAppearance(named: .darkAqua)
      host.frame = NSRect(x: 0, y: 0, width: 520, height: height)
      host.apply(showsGlass: true)
      host.layoutSubtreeIfNeeded()

      XCTAssertTrue(host.usesSystemGlass)
      XCTAssertFalse(host.hasVerticalOverlayForTesting, "no wash of ours, at \(height)")
      XCTAssertTrue(host.verticalOverlayColorsForTesting.isEmpty)
      XCTAssertEqual(host.glassTintAlphaForTesting, 0, accuracy: 0.001)
      XCTAssertEqual(try XCTUnwrap(host.layer).borderWidth, 0, "the glass draws its own rim")
    }
  }

  func testAGrownPromptWearsTheSameRamp() throws {
    func wash(height: CGFloat) throws -> [NSColor] {
      let host = PaletteGlassHost(
        content: NSView(),
        cornerRadius: AgentPaletteMetrics.cornerRadius,
        style: .bolttyAIPrompt
      )
      host.appearance = NSAppearance(named: .darkAqua)
      host.frame = NSRect(x: 0, y: 0, width: 540, height: height)
      host.apply(showsGlass: true)
      host.layoutSubtreeIfNeeded()
      return try host.verticalOverlayColorsForTesting.map {
        try XCTUnwrap(NSColor(cgColor: $0)?.usingColorSpace(.sRGB))
      }
    }

    let resting = try wash(height: 85)
    let grown = try wash(height: 200)
    XCTAssertEqual(resting.count, PaletteGlassRamp.resolution)
    XCTAssertEqual(grown.count, resting.count)
    for (lhs, rhs) in zip(resting, grown) {
      XCTAssertEqual(lhs.alphaComponent, rhs.alphaComponent, accuracy: 0.001)
    }

    for (index, stop) in resting.enumerated() {
      let location = CGFloat(index) / CGFloat(resting.count - 1)
      XCTAssertEqual(stop.redComponent, 0, accuracy: 0.005)
      XCTAssertEqual(stop.greenComponent, 0, accuracy: 0.005)
      XCTAssertEqual(stop.blueComponent, 0, accuracy: 0.005)
      XCTAssertEqual(
        stop.alphaComponent,
        1 - location,
        accuracy: 0.01,
        "the gradient is linear from 100% to 0%"
      )
    }
  }

  func testGlassDrawsAContinuousHairlineBorder() throws {
    let bare = PaletteGlassHost(content: NSView(), cornerRadius: 43, style: .bolttyAI)
    bare.frame = NSRect(x: 0, y: 0, width: 520, height: 56)
    bare.apply(showsGlass: true)
    bare.layoutSubtreeIfNeeded()
    XCTAssertEqual(try XCTUnwrap(bare.layer).borderWidth, 0, "the shell's rim is the glass's own")

    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 43,
      style: .plain
    )
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 56)
    host.apply(showsGlass: true)
    host.layoutSubtreeIfNeeded()

    let layer = try XCTUnwrap(host.layer)
    XCTAssertEqual(layer.cornerCurve, .circular)
    XCTAssertEqual(host.cornerCurveForTesting, layer.cornerCurve)
    XCTAssertGreaterThan(layer.borderWidth, 0)
    XCTAssertLessThanOrEqual(layer.borderWidth, 1)

    let color = try XCTUnwrap(
      NSColor(cgColor: try XCTUnwrap(layer.borderColor))?.usingColorSpace(.sRGB)
    )
    XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
    XCTAssertEqual(color.greenComponent, 1, accuracy: 0.01)
    XCTAssertEqual(color.blueComponent, 1, accuracy: 0.01)
    XCTAssertEqual(color.alphaComponent, PaletteGlassHost.edgeHighlightAlpha, accuracy: 0.001)
    XCTAssertLessThanOrEqual(color.alphaComponent, 0.22)

    for style in [PaletteSurfaceStyle.bolttyAI, .bolttyAIPrompt] {
      let bolttyAI = PaletteGlassHost(content: NSView(), cornerRadius: 43, style: style)
      bolttyAI.frame = host.frame
      bolttyAI.apply(showsGlass: true)
      bolttyAI.layoutSubtreeIfNeeded()
      XCTAssertEqual(try XCTUnwrap(bolttyAI.layer).borderWidth, 0, "the glass draws its own rim")
    }
  }

  func testOverlayStackNeverForcesAnOffscreenPass() {
    for style in [PaletteSurfaceStyle.bolttyAI, .bolttyAIPrompt] {
      let host = PaletteGlassHost(
        content: NSView(),
        cornerRadius: 49,
        style: style
      )
      host.frame = NSRect(x: 0, y: 0, width: 520, height: 98)
      host.apply(showsGlass: true)
      host.layoutSubtreeIfNeeded()

      XCTAssertTrue(host.overlayAvoidsOffscreenPassForTesting)
    }
  }

  func testTheShellIsTheBareGlassAndThePromptAloneWearsTheRamp() {
    let shell = PaletteSurfaceStyle.bolttyAI
    XCTAssertEqual(shell.material, .regular)
    XCTAssertNil(shell.wash, "no wash of ours over the system's glass")
    XCTAssertEqual(shell.edgeAlpha, 0, "the glass draws its own rim")
    XCTAssertEqual(shell.glassTintAlpha, 0, "and no tint in it")
    XCTAssertFalse(
      shell.drawsOuterShadow,
      "elevation belongs to the capsule container; glass clips a shadow set here"
    )
    XCTAssertEqual(PaletteSurfaceStyle.bolttyAIControl, shell)
    XCTAssertEqual(PaletteSurfaceStyle.bolttyAIComposer, shell)

    let prompt = PaletteSurfaceStyle.bolttyAIPrompt
    XCTAssertEqual(prompt.material, .regular)
    XCTAssertEqual(prompt.wash, .bolttyAIPromptRamp)
    XCTAssertEqual(prompt.wash?.glassTintAlpha, 0, "a tint would floor the foot")
    XCTAssertEqual(prompt.edgeAlpha, 0)
    XCTAssertEqual(prompt.glassTintAlpha, 0)
    XCTAssertFalse(prompt.drawsOuterShadow)
  }

  func testInnerTopShadowPinsALipToTheCrownInPoints() throws {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 24,
      style: .bolttyAIPrompt
    )
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
    host.apply(showsGlass: true)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(host.hasVerticalOverlayForTesting, "the lip is drawn in the wash's view")

    let frame = host.innerTopShadowFrameForTesting
    XCTAssertEqual(frame.height, PaletteGlassHost.innerTopShadowHeight, accuracy: 0.5)
    XCTAssertEqual(frame.maxY, host.bounds.maxY, accuracy: 0.5)

    let colors = host.innerTopShadowColorsForTesting
    let crown = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(colors.first))?.usingColorSpace(.sRGB))
    let fade = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(colors.last))?.usingColorSpace(.sRGB))
    XCTAssertGreaterThan(crown.alphaComponent, fade.alphaComponent)
    XCTAssertEqual(fade.alphaComponent, 0, accuracy: 0.001)
  }

  func testFloatingHUDShadowMatchesBolttyAIElevation() {
    let host = PaletteGlassHost(content: NSView(), cornerRadius: 28)
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 56)
    host.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      host.shadowOpacityForTesting,
      PaletteGlassHost.floatingShadowOpacity,
      accuracy: 0.001
    )
    XCTAssertEqual(
      host.shadowRadiusForTesting,
      PaletteGlassHost.floatingShadowRadius,
      accuracy: 0.001
    )
    XCTAssertEqual(
      host.shadowOffsetForTesting.height,
      PaletteGlassHost.floatingShadowOffset.height,
      accuracy: 0.001
    )

    XCTAssertGreaterThanOrEqual(PaletteGlassHost.floatingShadowOpacity, 0.3)
    XCTAssertLessThanOrEqual(PaletteGlassHost.floatingShadowRadius, 16)
    XCTAssertLessThan(PaletteGlassHost.floatingShadowOffset.height, 0)
  }

  func testStandardBackgroundLayerUsesHostCornerRadius() throws {
    let radius: CGFloat = 24
    let host = PaletteGlassHost(content: NSView(), cornerRadius: radius)

    host.apply(showsGlass: false)

    let solidLayerView = try XCTUnwrap(host.subviews.first)
    let layer = try XCTUnwrap(solidLayerView.layer)
    XCTAssertEqual(layer.cornerRadius, radius)
  }

  func testStandardKeepsHostedContentAboveHiddenGlassEffect() {
    let host = PaletteGlassHost(content: NSView(), cornerRadius: 24)

    host.apply(showsGlass: false)

    XCTAssertTrue(host.hostedContentView.superview === host)
    XCTAssertFalse(host.hostedContentView.isHidden)
  }

  func testStandardBackgroundDrawsAnEdgeBorder() throws {
    let host = PaletteGlassHost(content: NSView(), cornerRadius: 24)

    host.apply(showsGlass: false)

    let layer = try XCTUnwrap(host.layer)
    XCTAssertEqual(layer.cornerCurve, .continuous)
    XCTAssertGreaterThan(layer.borderWidth, 0)
    XCTAssertNotNil(layer.borderColor)
  }

  func testShadowPathUsesFullCapsuleBoundsAndExactRadius() throws {
    let host = PaletteGlassHost(content: NSView(), cornerRadius: 43)
    host.frame = NSRect(x: 0, y: 0, width: 520, height: 86)
    host.layoutSubtreeIfNeeded()

    let path = try XCTUnwrap(host.layer?.shadowPath)
    XCTAssertEqual(path.boundingBox, host.bounds)
    XCTAssertEqual(host.shadowCornerRadiusForTesting, 43)
  }

  func testTheGlassDrawsItsOwnCornerAndNothingOfOursClipsIt() throws {
    let host = PaletteGlassHost(
      content: NSView(),
      cornerRadius: 49,
      style: .bolttyAIPrompt
    )
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 540, height: 85)
    let window = NSWindow(
      contentRect: host.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = host
    host.apply(showsGlass: true)
    host.layoutSubtreeIfNeeded()

    XCTAssertEqual(host.cornerCurveForTesting, .circular)
    XCTAssertFalse(
      host.effectViewClipsToCornerForTesting,
      "a clip on the material cuts away the rim it draws along its edge"
    )
    XCTAssertEqual(host.renderedCornerRadius, min(49, host.bounds.height / 2), accuracy: 0.01)
    XCTAssertEqual(
      host.effectCornerRadiusForTesting, host.renderedCornerRadius, accuracy: 0.01,
      "the glass draws the capsule's own corner, not 0 under a clip of ours"
    )

    host.frame.size.height = 200
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.cornerCurveForTesting, .continuous)
    XCTAssertEqual(host.effectCornerRadiusForTesting, 49,
      "a taller card keeps the native continuous corner")
    XCTAssertFalse(host.effectViewClipsToCornerForTesting)
  }

  func testTheComposerIsTheShellsOwnGlass() throws {
    let composer = PaletteGlassHost(
      content: NSView(), cornerRadius: 25, style: .bolttyAIComposer
    )
    composer.appearance = NSAppearance(named: .darkAqua)
    composer.frame = NSRect(x: 0, y: 0, width: 464, height: 50)
    composer.apply(showsGlass: true)
    composer.layoutSubtreeIfNeeded()

    XCTAssertTrue(composer.usesSystemGlass)
    XCTAssertFalse(composer.hasVerticalOverlayForTesting, "no well of ours over it")
    XCTAssertTrue(composer.verticalOverlayColorsForTesting.isEmpty)
    XCTAssertEqual(composer.effectiveGlassTintAlpha, 0, accuracy: 0.001)
    XCTAssertEqual(composer.glassTintAlphaForTesting, 0, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(composer.layer).borderWidth, 0)
  }

  func testASurfaceStyleCanBeSwappedOnALiveHost() {
    let host = PaletteGlassHost(
      content: NSView(), cornerRadius: 42.5, style: .bolttyAIPrompt
    )
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(x: 0, y: 0, width: 540, height: 85)
    host.apply(showsGlass: true)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(host.hasVerticalOverlayForTesting)

    host.apply(surfaceStyle: .bolttyAI)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.surfaceStyleForTesting, .bolttyAI)
    XCTAssertFalse(host.hasVerticalOverlayForTesting, "the ramp goes with the first screen")
    XCTAssertTrue(host.verticalOverlayColorsForTesting.isEmpty)

    host.apply(surfaceStyle: .bolttyAIPrompt)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.surfaceStyleForTesting, .bolttyAIPrompt)
    XCTAssertTrue(host.hasVerticalOverlayForTesting, "and comes back with it")
    XCTAssertEqual(host.verticalOverlayColorsForTesting.count, PaletteGlassRamp.resolution)
  }
}

@MainActor
final class ReducedTransparencyFallbackTests: XCTestCase {
  func testTheOpaqueFallbackIsStillTheBlackTheThemeChainResolvedTo() throws {
    let colour = try XCTUnwrap(
      PaletteGlassHost.reducedTransparencyFill.usingColorSpace(.sRGB)
    )
    XCTAssertEqual(colour.redComponent, 0, accuracy: 0.001)
    XCTAssertEqual(colour.greenComponent, 0, accuracy: 0.001)
    XCTAssertEqual(colour.blueComponent, 0, accuracy: 0.001)
    XCTAssertEqual(colour.alphaComponent, 1, accuracy: 0.001)
  }

  func testHexColourStillParses() throws {
    let blue = try XCTUnwrap(HexColor.nsColor("#4396ff").usingColorSpace(.sRGB))
    XCTAssertEqual(blue.redComponent, 0x43 / 255, accuracy: 0.001)
    XCTAssertEqual(blue.greenComponent, 0x96 / 255, accuracy: 0.001)
    XCTAssertEqual(blue.blueComponent, 1, accuracy: 0.001)
    XCTAssertEqual(HexColor.nsColor("nope"), NSColor.windowBackgroundColor)
  }
}
