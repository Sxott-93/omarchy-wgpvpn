import QtQuick
import qs.Commons

// Key mark for the VPN widget, drawn from primitives (Qt-SVG rendering has
// quirks at bar sizes): a round head, a shaft, two teeth on a 16-unit grid.
Item {
  id: root

  property color color: "white"

  implicitWidth: 16
  implicitHeight: 16

  // One sixteenth of the drawn size; every dimension below is grid * s.
  readonly property real s: Math.min(width || 16, height || 16) / 16.0

  Rectangle {
    x: 0.5 * root.s
    y: 3.6 * root.s
    width: 8.8 * root.s
    height: 8.8 * root.s
    radius: 4.4 * root.s
    color: root.color
  }
  Rectangle {
    x: 8.5 * root.s
    y: 6.9 * root.s
    width: 7.0 * root.s
    height: 2.2 * root.s
    color: root.color
  }
  Rectangle {
    x: 13.3 * root.s
    y: 9.1 * root.s
    width: 1.9 * root.s
    height: 2.7 * root.s
    color: root.color
  }
  Rectangle {
    x: 10.6 * root.s
    y: 9.1 * root.s
    width: 1.9 * root.s
    height: 1.8 * root.s
    color: root.color
  }
}
