# <p align="center">![icon_transparent.png](OpenParsec/Assets.xcassets/IconTransparent.imageset/icon_transparent.png) ![OpenParsec](OpenParsec/Assets.xcassets/LogoShadow.imageset/logo_shadow.png)</p>

OpenParsec is a simple, open-source Parsec client for iOS/iPadOS written in Swift using UIKit and the Parsec SDK. The app supports arm64 devices running iOS 12.0 or later.

## Mac host companion

macOS does not allow a Parsec client to change the captured display resolution, and the pinned SDK does not continuously report cursor movement originating on the host. Install `OpenParsecHost.app` on the Mac to solve both limitations:

1. Download `OpenParsecHost.zip`, move the app to Applications, and open it. If Gatekeeper blocks the ad-hoc build, right-click the app and choose Open.
2. Keep the iPad and Mac on the same local network. Prefer 5 GHz Wi-Fi or connect the Mac by Ethernet.
3. In OpenParsec's host list, tap **Pair Mac**, then enter the six-digit code shown in the Mac menu-bar item.
4. Connect normally. The companion selects a real low-resolution 60 Hz Mac display mode before Parsec starts and draws a capture-visible cursor for movement originating on either device.

The first-generation iPad Air profile starts with H.264 hardware decoding, 1920×1200, 60 FPS, and 10 Mbps. It samples decode, encode, queue, retransmission, and network metrics, reducing bitrate or resolution when the 60 FPS frame budget cannot be maintained. The optimized Mac display mode remains active after disconnect; use the companion menu to restore the original Retina mode manually.

This project is still a major WIP, so apologies for the currently lackluster documentation. I'm also very new to both Swift and SwiftUI so I'm sure there are many places for improvement.

Before building, initialize the pinned Parsec SDK framework with `git submodule update --init --recursive`. Build and runtime validation for iOS 12 requires an Xcode release that can deploy to iOS 12 and an arm64 iOS 12 device.

## Downloads
<a href="https://stikstore.app/altdirect/?url=https://github.com/hugeBlack/OpenParsec/releases/download/nightly/altstore.json" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200">
</a>
<a href="https://github.com/hugeBlack/OpenParsec/releases/download/nightly/OpenParsec.ipa" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200">
</a>

## Touch Control
You can set the touch mode you want to use in settings. Touchpad mode and direct touch mode are supported.

When streaming, you can tap with 3 fingers to bring up the on-screen keyboard.

You can toggle if you want to use 2 fingers to scroll or zoom in the overlay menu.

## Mouse & keyboard
USB mouse & keyboard are supported. 

## Game Controllers
When streaming, press any trigger button in your controller and parsec will recognize it. Make sure to configure the host properly (install virtual USB driver etc.) before using game controllers.

## Lag / Low Bitrate Issue
If you encounter lags from nowhere or your bitrate hardly goes over 10 Mbps, download Steam Link and do a network test. If you see constant lag spike in the graph, then it's a problem with Apple and there's little we can do to solve this problem. See [here](https://github.com/moonlight-stream/moonlight-ios/issues/627) for more disscussion. 

If you can't change your wireless router's channel to 149 like me, my personal experience is that you can try to power off the device you are using to stream as well as any nearby Apple devices, especially Mac, then only power on the device you are using to stream and do the aforementioned network test again. You can turn on other devices if the lag spike is gone and it may sustain for couple hours or days.
