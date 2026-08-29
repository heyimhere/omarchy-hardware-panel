import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

// Bar-widget entry point: a compact "CPU 18%  GPU 6%" row in the bar that
// opens a popup panel with CPU/GPU/Memory/Fans sections on click. Follows
// the single-file bar-row + popup pattern used by omarchy.monitor and
// omarchy.tailscale (qs.Ui.Panel base + KeyboardPanel popup).
Panel {
  id: root
  moduleName: "io.github.heyimhere.hardware-panel"
  ipcTarget: "io.github.heyimhere.hardware-panel"
  // The singleton HardwareService owns the IPC target and routes commands
  // through the shell to the appropriate live bar-widget instance.
  manageIpc: false

  readonly property var hardwareService: bar && bar.shell
    ? bar.shell.serviceFor("io.github.heyimhere.hardware-panel") : null
  readonly property var gpus: hardwareService ? hardwareService.gpus : []
  readonly property var fans: hardwareService ? hardwareService.fans : []
  readonly property var barGpu: {
    for (var i = 0; i < gpus.length; i++)
      if (gpus[i].utilPercent !== null) return gpus[i]
    return null
  }

  function configuredRefreshInterval() {
    var value = settings ? settings.refreshIntervalSec : 2
    var parsed = parseInt(String(value === undefined ? 2 : value), 10)
    return isFinite(parsed) ? parsed : 2
  }

  function configureService() {
    if (hardwareService)
      hardwareService.configureRefreshInterval(configuredRefreshInterval())
  }

  onHardwareServiceChanged: configureService()
  onSettingsChanged: configureService()
  Component.onCompleted: configureService()

  // "CPU 18%  GPU 6%": CPU segment shown once a sample exists, GPU segment
  // appended only when a GPU was actually detected. Never an empty shell.
  // If nothing is available at all, the widget hides itself entirely.
  readonly property string compactBarText: {
    var parts = []
    if (hardwareService && hardwareService.cpuPercent >= 0)
      parts.push("CPU " + Math.round(hardwareService.cpuPercent) + "%")
    if (barGpu)
      parts.push("GPU " + Math.round(barGpu.utilPercent) + "%")
    return parts.join("  ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: compactBarText !== ""

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.compactBarText
    tooltipText: "CPU / GPU / Memory / Fans, click for details"
    onPressed: function (b) {
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(col.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: col.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: col
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          PanelHero {
            iconComponent: Component {
              Text {
                text: ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            title: "Hardware"
            // The detail pill has no eliding and isn't clamped to the panel's
            // width, so a variable-length phrase like "Installed 118 days"
            // can render past the popup's own border. meta.elide handles
            // this safely, and doubles as the error line when one is active.
            meta: hardwareService && hardwareService.lastError !== ""
              ? "Last update failed"
              : (hardwareService && hardwareService.osAgeDays !== null
                  ? "Installed " + hardwareService.osAgeDays
                    + (hardwareService.osAgeDays === 1 ? " day" : " days")
                  : "")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          // ---------- CPU ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "CPU"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              width: parent.width
              visible: hardwareService && !!hardwareService.cpuName
              text: hardwareService ? hardwareService.cpuName : ""
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Row {
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: hardwareService && hardwareService.cpuPercent >= 0
                  ? Math.round(hardwareService.cpuPercent) + "%" : "N/A"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                visible: hardwareService && hardwareService.cpuTempC !== null
                anchors.verticalCenter: parent.verticalCenter
                text: hardwareService && hardwareService.cpuTempC !== null
                  ? Math.round(hardwareService.cpuTempC) + "°C" : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---------- GPUs (whole section omitted when none detected) ----------
          PanelSeparator {
            visible: root.gpus.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            visible: root.gpus.length > 0
            spacing: Style.space(10)

            PanelSectionHeader {
              text: root.gpus.length > 1 ? "GPUS" : "GPU"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.gpus

              Column {
                required property var modelData
                required property int index
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  text: modelData.name
                  color: root.gpus.length > 1 ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.gpus.length > 1 ? Style.font.body : Style.font.caption
                  font.bold: root.gpus.length > 1
                  elide: Text.ElideRight
                }

                Row {
                  spacing: Style.space(10)

                  Text {
                    visible: modelData.utilPercent !== null
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.utilPercent !== null ? Math.round(modelData.utilPercent) + "%" : ""
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Text {
                    visible: modelData.tempC !== null
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.tempC !== null ? Math.round(modelData.tempC) + "°C" : ""
                    color: modelData.utilPercent === null ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: modelData.utilPercent === null ? Style.font.title : Style.font.body
                    font.bold: modelData.utilPercent === null
                  }

                  Text {
                    visible: modelData.fanPercent !== null
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.fanPercent !== null ? "Fan " + Math.round(modelData.fanPercent) + "%" : ""
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                Text {
                  visible: modelData.utilPercent === null
                  text: "Utilization unavailable"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: modelData.memTotalMB !== null
                  text: modelData.memTotalMB !== null
                    ? (modelData.memUsedMB !== null ? (modelData.memUsedMB / 1024).toFixed(1) : "N/A")
                      + " / " + (modelData.memTotalMB / 1024).toFixed(1) + " GB VRAM"
                    : ""
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---------- Memory ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "MEMORY"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Row {
              spacing: Style.space(10)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (hardwareService && hardwareService.memUsedGB >= 0 ? hardwareService.memUsedGB.toFixed(1) : "N/A")
                      + " / " + (hardwareService && hardwareService.memTotalGB >= 0 ? hardwareService.memTotalGB.toFixed(1) : "N/A") + " GB"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                visible: hardwareService && hardwareService.memPercent >= 0
                anchors.verticalCenter: parent.verticalCenter
                text: hardwareService && hardwareService.memPercent >= 0
                  ? Math.round(hardwareService.memPercent) + "%" : ""
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---------- Fans (whole section omitted when none detected) ----------
          PanelSeparator {
            visible: root.fans.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            visible: root.fans.length > 0
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "FANS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.fans

              Item {
                required property var modelData
                width: parent.width
                implicitHeight: Math.max(fanLabel.implicitHeight, fanRpm.implicitHeight)

                Text {
                  id: fanLabel
                  anchors.left: parent.left
                  anchors.right: fanRpm.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  id: fanRpm
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.rpm + " RPM"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }
}
