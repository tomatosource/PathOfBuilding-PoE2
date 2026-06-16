#include <string_view>
#include <functional>
#include <CoreFoundation/CFBundle.h>
#include <ApplicationServices/ApplicationServices.h>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include "engine/common/keylist.h"

const char* PlatformOpenURL(const char* textUrl)
{
    std::string_view urlView = textUrl;
    CFURLRef url = CFURLCreateWithBytes(nullptr, (const UInt8*)urlView.data(), urlView.size(), kCFStringEncodingUTF8, nullptr);
    LSOpenCFURLRef(url, nullptr);
    CFRelease(url);
    return nullptr;
}

// Trackpad pinch-to-zoom: accumulate magnification and synthesise scroll events.
// Called once after window creation; fires KEY_MWHEELUP/DOWN via the supplied callback.
static std::function<void(int, int)> s_pinchCallback;
static CGFloat s_pinchAccum = 0.0;
static id s_pinchMonitor = nil;

void PlatformSetupMagnification(std::function<void(int, int)> callback)
{
    s_pinchCallback = callback;
    if (s_pinchMonitor) return;
    s_pinchMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                                          handler:^NSEvent*(NSEvent* event) {
        if (!s_pinchCallback) return event;
        s_pinchAccum += (CGFloat)event.magnification;
        // Fire one discrete zoom step per ~0.07 units of magnification.
        while (s_pinchAccum >= 0.07) {
            s_pinchCallback(KEY_MWHEELUP, KE_KEYDOWN);
            s_pinchCallback(KEY_MWHEELUP, KE_KEYUP);
            s_pinchAccum -= 0.07;
        }
        while (s_pinchAccum <= -0.07) {
            s_pinchCallback(KEY_MWHEELDOWN, KE_KEYDOWN);
            s_pinchCallback(KEY_MWHEELDOWN, KE_KEYUP);
            s_pinchAccum += 0.07;
        }
        return event;
    }];
}

// Fix the Retina quarter-render issue: ANGLE/EGL creates a CAMetalLayer with
// contentsScale=1.0, which places the 1x drawable in the lower-left quarter
// of the 2x Retina physical framebuffer.  Set every sublayer's contentsScale
// to the display backing scale factor so the drawable covers the full window.
void PlatformFixRetinaLayer(GLFWwindow* window)
{
    NSWindow* nswin = glfwGetCocoaWindow(window);
    if (!nswin) return;
    NSView* view = [nswin contentView];
    if (!view || !view.layer) return;
    CGFloat scale = [nswin backingScaleFactor];
    view.layer.contentsScale = scale;
    for (CALayer* sub in view.layer.sublayers) {
        sub.contentsScale = scale;
        for (CALayer* sub2 in sub.sublayers) {
            sub2.contentsScale = scale;
        }
    }
}
