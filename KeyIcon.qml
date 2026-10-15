import QtQuick
import QtQuick.Shapes

// Skeleton key for the VPN widget, drawn as one vector path (the same
// PathSvg technique the shell's overlays use): a ring bow with a real hole
// (outer circle wound clockwise, the hole counter-clockwise, winding fill),
// a slim shaft, and a two-step bit at the tip. All coordinates are on a
// 16-unit grid, scaled to the drawn size.
Shape {
  id: root

  property color color: "white"

  implicitWidth: 16
  implicitHeight: 16

  // One sixteenth of the drawn size.
  readonly property real s: Math.min(width || 16, height || 16) / 16.0

  // The key on a 16-unit grid, scaled to the drawn size. Winding: the ring's
  // outer circle is wound clockwise and its hole counter-clockwise, so the
  // winding fill leaves a real hole; every other subpath is clockwise and
  // overlaps its neighbour by 0.1 units so joins stay solid.
  readonly property string pathData: {
    function c(v) { return (v * root.s).toFixed(3) }
    return "M " + c(7.6) + " " + c(8) +
           " A " + c(3.4) + " " + c(3.4) + " 0 1 1 " + c(0.8) + " " + c(8) +
           " A " + c(3.4) + " " + c(3.4) + " 0 1 1 " + c(7.6) + " " + c(8) + " Z " +
           "M " + c(5.9) + " " + c(8) +
           " A " + c(1.7) + " " + c(1.7) + " 0 1 0 " + c(2.5) + " " + c(8) +
           " A " + c(1.7) + " " + c(1.7) + " 0 1 0 " + c(5.9) + " " + c(8) + " Z " +
           "M " + c(7.4) + " " + c(7.15) +
           " L " + c(15.4) + " " + c(7.15) +
           " L " + c(15.4) + " " + c(8.85) +
           " L " + c(7.4) + " " + c(8.85) + " Z " +
           "M " + c(11.6) + " " + c(8.75) +
           " L " + c(13.3) + " " + c(8.75) +
           " L " + c(13.3) + " " + c(11.1) +
           " L " + c(11.6) + " " + c(11.1) + " Z " +
           "M " + c(13.3) + " " + c(8.75) +
           " L " + c(15.4) + " " + c(8.75) +
           " L " + c(15.4) + " " + c(10.3) +
           " L " + c(13.3) + " " + c(10.3) + " Z"
  }

  antialiasing: true

  ShapePath {
    fillColor: root.color
    fillRule: ShapePath.WindingFill
    strokeWidth: 0

    PathSvg { path: root.pathData }
  }
}
