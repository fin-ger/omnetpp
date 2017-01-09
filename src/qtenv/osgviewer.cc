//==========================================================================
//  OSGVIEWER.CC - part of
//
//                     OMNeT++/OMNEST
//            Discrete System Simulation in C++
//
//==========================================================================

/*--------------------------------------------------------------*
  Copyright (C) 1992-2017 Andras Varga
  Copyright (C) 2006-2017 OpenSim Ltd.

  This file is distributed WITHOUT ANY WARRANTY. See the file
  `license' for details on this and other legal matters.
*--------------------------------------------------------------*/

#ifdef WITH_OSG

#include <QDebug>
#include <QToolTip>
#include <QMenu>
#include <QResizeEvent>
#include <QOffscreenSurface>
#include <QOpenGLFunctions>

#ifdef WITH_OSGEARTH
#include <osgEarth/Version>
#if OSGEARTH_VERSION_GREATER_OR_EQUAL(2, 6, 0)
    #include <osgEarthUtil/Sky>
#else
    #include <osgEarthUtil/SkyNode>
#endif
#include <osgEarth/MapNode>
#include <osgEarthUtil/EarthManipulator>
#endif

#include <osgDB/DatabasePager>
#include <osgGA/TerrainManipulator>
#include <osgGA/TrackballManipulator>
#include <osg/TexGenNode>
#include <osgUtil/Optimizer>
#include <osg/Depth>
#include <osg/DeleteHandler>
#include <osg/Version>
#include "omnetpp/osgutil.h"
#include "inspectorutil.h"
#include "osgviewer.h"
#include "cameramanipulators.h"

namespace omnetpp {
namespace qtenv {

#define emit

//  --------  GraphicsWindow  --------

class GraphicsWindow : public osgViewer::GraphicsWindowEmbedded {
    OsgViewer *v = nullptr;
    QOpenGLContext *c = nullptr;
    QOffscreenSurface *s = nullptr;

    static QSurfaceFormat traitsToSurfaceFormat(const osg::GraphicsContext::Traits *traits) {
        QSurfaceFormat format;

        format.setRedBufferSize(traits->red);
        format.setGreenBufferSize(traits->green);
        format.setBlueBufferSize(traits->blue);

        format.setAlphaBufferSize(traits->alpha);
        format.setDepthBufferSize(traits->depth);
        format.setStencilBufferSize(traits->stencil);

        // Enabling multisampling breaks OpenGL (osgCanvas) video recording,
        // specifically grabFramebuffer() with Qt versions prior 5.6.0.
        // see https://bugreports.qt.io/browse/QTBUG-48450
        // I think this should check the version Qtenv is running with, not
        // the one it has been compiled with, but that seemed nontrivial.
#if (QT_VERSION >= QT_VERSION_CHECK(5, 6, 0))
        format.setSamples(traits->samples);
#else
        format.setSamples(1);
#endif

        format.setSwapBehavior(traits->doubleBuffer
                               ? QSurfaceFormat::DoubleBuffer
                               : QSurfaceFormat::SingleBuffer);

        format.setSwapInterval(traits->vsync ? 1 : 0);
        format.setStereo(traits->quadBufferStereo);

        return format;
    }

public:
    GraphicsWindow(OsgViewer *v, int x, int y, int w, int h) : GraphicsWindowEmbedded(x, y, w, h), v(v) {
        auto state = new osg::State;
        setState(state);
        state->setGraphicsContext(this);
        // This ID is just an internal unique handle for OSG,
        // real context creation is done entirely by Qt.
        state->setContextID(osg::GraphicsContext::createNewContextID());
        v->setFormat(traitsToSurfaceFormat(getTraits()));
    }

    GraphicsWindow(OsgViewer *v, osg::GraphicsContext::Traits *t) : GraphicsWindowEmbedded(t), v(v) {
        auto state = new osg::State;
        setState(state);
        state->setGraphicsContext(this);
        // This ID is just an internal unique handle for OSG,
        // real context creation is done entirely by Qt.
        state->setContextID(osg::GraphicsContext::createNewContextID());
        v->setFormat(traitsToSurfaceFormat(t));
    }

    GraphicsWindow(osg::GraphicsContext::Traits *t) : GraphicsWindowEmbedded(t) {
        c = new QOpenGLContext();
        s = new QOffscreenSurface();
        s->setFormat(traitsToSurfaceFormat(t));
        auto state = new osg::State;
        setState(state);
        state->setGraphicsContext(this);
        // This ID is just an internal unique handle for OSG,
        // real context creation is done entirely by Qt.
        state->setContextID(osg::GraphicsContext::createNewContextID());
    }

    void resizedImplementation(int x, int y, int width, int height) override {
        setDefaultFboId(c ? c->defaultFramebufferObject() : v->defaultFramebufferObject());

        GraphicsWindowEmbedded::resizedImplementation(x, y, width, height); // ?
        if (v) v->resize(width, height), v->update();
    }

    bool realizeImplementation() override {
        if (c) {
            s->create();
            bool ret = c->create();
            setDefaultFboId(c->defaultFramebufferObject());
            return ret;
        }
        else {
            setDefaultFboId(v->defaultFramebufferObject());
            return v && v->context();
        }
    }

    bool makeCurrentImplementation() override {
        if (c)
            c->makeCurrent(s);
        else
            v->makeCurrent();

        return c || v->context();
    }

    bool releaseContextImplementation() override {
        if (v && v->context()) {
            QOpenGLFunctions funcs(v->context());
            funcs.initializeOpenGLFunctions();

            // ensuring that only alpha will be affected by the clear
            funcs.glColorMask(0, 0, 0, 1);
            // setting the alpha clear color it to fully opaque
            funcs.glClearColor(0, 0, 0, 1);
            // and doing the clear, it's sufficient to do it on the color buffer only
            funcs.glClear(GL_COLOR_BUFFER_BIT);
        }

        c ? c->doneCurrent() : v->doneCurrent();
        return true;
    }

    bool isRealizedImplementation() const override {
        return c || v->context();
    }

    void swapBuffersImplementation() override {
        if (v) {
            // No manual buffer swapping, as in the newer QOpenGLWidget
            // all rendering is done in a magical way into an FBO,
            // and this will basically blit that onto the screen.

            // Well except of course on Mac it has to be done differently...
            #ifdef Q_OS_MAC
                v->context()->swapBuffers(v->context()->surface());
            #endif

            v->update();
        }
    }
};

//  --------  WindowingSystemInterface  --------

struct WindowingSystemInterface : public osg::GraphicsContext::WindowingSystemInterface {

    static WindowingSystemInterface *getInterface() {
        static WindowingSystemInterface *intf = new WindowingSystemInterface;
        return intf;
    }

    unsigned int getNumScreens(const osg::GraphicsContext::ScreenIdentifier&) override {
        return 0; // not implemented
    }

    void getScreenSettings(const osg::GraphicsContext::ScreenIdentifier&, osg::GraphicsContext::ScreenSettings&) override {
        // not implemented
    }

    void enumerateScreenSettings(const osg::GraphicsContext::ScreenIdentifier&, osg::GraphicsContext::ScreenSettingsList&) {
        // not implemented
    }

    osg::GraphicsContext *createGraphicsContext(osg::GraphicsContext::Traits *traits) override {
        return traits->pbuffer
                ? nullptr // no pbuffer support
                : new GraphicsWindow(traits);
    }

    ~WindowingSystemInterface() {
        if (auto dh = osg::Referenced::getDeleteHandler()) {
            dh->setNumFramesToRetainObjects(0);
            dh->flushAll();
        }
    }
};

//  --------  HeartBeat  --------

HeartBeat *HeartBeat::instance = nullptr;

HeartBeat::HeartBeat(osg::ref_ptr<osgViewer::CompositeViewer> viewer, QObject *parent)
    : QObject(parent), viewer(viewer) {
    ASSERT2(!instance, "Only one instance of HeartBeat can exist at any time.");
}

void HeartBeat::init(osg::ref_ptr<osgViewer::CompositeViewer> viewer) {
    if (!instance)
        instance = new HeartBeat(viewer, getQtenv());
}

void HeartBeat::start() {
    // TODO: make this cooperate with the dynamic FPS mechanism of the 2D canvases
    if (!instance->timer.isActive())
        instance->timer.start(1000 / 60, Qt::PreciseTimer, instance); // 60 FPS master race, yeah
}

void HeartBeat::uninit() {
    ASSERT2(instance, "No HeartBeat instance exists upon uninit()");

    instance->timer.stop();
    instance->viewer = nullptr;

    delete instance;
    instance = nullptr;
}

void HeartBeat::timerEvent(QTimerEvent *event) {
    if ((viewer->getRunFrameScheme() == osgViewer::CompositeViewer::CONTINUOUS)
            || viewer->checkNeedToDoFrame()) {
        viewer->frame();
    }
}

//  --------  OsgViewer  --------

osg::ref_ptr<osgViewer::CompositeViewer> OsgViewer::viewer = nullptr;

OsgViewer::OsgViewer(QWidget *parent): QOpenGLWidget(parent)
{
    if (!viewer.valid()) { // this is the validity of the pointer, not of the viewer
#if OSG_VERSION_GREATER_OR_EQUAL(3, 5, 0)
        osg::GraphicsContext::getWindowingSystemInterfaces()->addWindowingSystemInterface(WindowingSystemInterface::getInterface());
#else
        osg::GraphicsContext::setWindowingSystemInterface(WindowingSystemInterface::getInterface());
#endif

        viewer = new osgViewer::CompositeViewer();

        // Multithreaded rendering does not play well with the fact that
        // our GL contexts are managed by Qt. It might be possible to
        // make it work, but no reason so far fo make that much effort.
        viewer->setThreadingModel(osgViewer::CompositeViewer::SingleThreaded);

        // Set this to CONTINUOUS to avoid the "multiple views with trackball manipulator" issue.
        // Which is the following: If two views with TrackballManipulator are thrown at the
        // same time (so that they are spinning on their own), and one of them is stopped,
        // the manipulator requests the viewer to no longer update (redraw) continuously,
        // and as a result, the picture in the other view freezes, even though the manipulator
        // is still spinning, and the camera in it will snap into a new position upon the next redraw.
        // But that will have the price of always rendering new frames, even if nothing has
        // changed, and the resulting frame would be the same, so lets keep it ON_DEMAND,
        // we can live with these minor consequences (for now at least).
        // This whole thing does not apply to osgEarth, as it always requests redraw.
        viewer->setRunFrameScheme(osgViewer::CompositeViewer::ON_DEMAND);

        HeartBeat::init(viewer);
    }

    auto traits = new osg::GraphicsContext::Traits;
    traits->x = x();
    traits->y = y();
    traits->width = width();
    traits->height = height();
    traits->samples = 4; // XXX make this configurable?

    graphicsWindow = new GraphicsWindow(this, traits);

    // to prevent the default Qt context menu handling, we will do it manually
    setContextMenuPolicy(Qt::NoContextMenu);
    // so the widget can receive focus, and forward the event to OSG
    setFocusPolicy(Qt::WheelFocus);

    QActionGroup *cameraManipulatorActionGroup = new QActionGroup(this); // will provide radiobutton functionality
    connect(cameraManipulatorActionGroup, SIGNAL(triggered(QAction*)), this, SLOT(setCameraManipulator(QAction*)));

    toTerrainManipulatorAction = new QAction("Terrain", this);
    toTerrainManipulatorAction->setData(cOsgCanvas::CAM_TERRAIN);
    toTerrainManipulatorAction->setActionGroup(cameraManipulatorActionGroup);
    toTerrainManipulatorAction->setCheckable(true);

    toOverviewManipulatorAction = new QAction("Overview", this);
    toOverviewManipulatorAction->setData(cOsgCanvas::CAM_OVERVIEW);
    toOverviewManipulatorAction->setActionGroup(cameraManipulatorActionGroup);
    toOverviewManipulatorAction->setCheckable(true);

    toTrackballManipulatorAction = new QAction("Trackball", this);
    toTrackballManipulatorAction->setData(cOsgCanvas::CAM_TRACKBALL);
    toTrackballManipulatorAction->setActionGroup(cameraManipulatorActionGroup);
    toTrackballManipulatorAction->setCheckable(true);

#ifdef WITH_OSGEARTH
    toEarthManipulatorAction = new QAction("Earth", this);
    toEarthManipulatorAction->setData(cOsgCanvas::CAM_EARTH);
    toEarthManipulatorAction->setActionGroup(cameraManipulatorActionGroup);
    toEarthManipulatorAction->setCheckable(true);
#endif

    view = new osgViewer::View;
    view->getDatabasePager()->setUnrefImageDataAfterApplyPolicy(true,false);

    camera = view->getCamera();
    camera->setViewport(0, 0, width(), height());
    camera->setClearColor(osg::Vec4(0, 0, 1, 1));
    camera->setProjectionMatrixAsPerspective(30.f, widgetAspectRatio(), 1.0f, 1000.0f);
    camera->setGraphicsContext(graphicsWindow);
    defaultComputeNearFarMode = camera->getComputeNearFarMode();
}

bool OsgViewer::event(QEvent *event)
{
    if (event->type() == QEvent::ToolTip) {
        QHelpEvent *helpEvent = (QHelpEvent *)event;

        cComponent *comp = nullptr;
        auto objects = objectsAt(helpEvent->pos());
        for (auto o : objects) {
            if ((comp = dynamic_cast<cComponent *>(o)))
                break;
        }

        QPoint pos = helpEvent->pos();
        auto offs = QPoint(10, 10);
        QRect rect(pos-offs, pos+offs);

        if (comp)
            QToolTip::showText(helpEvent->globalPos(),
                               makeObjectTooltip(comp),
                               this, rect);
        else
            QToolTip::hideText();
    }

    if (event->type() == QEvent::FocusIn) {
        viewer->setCameraWithFocus(camera);
    }

    bool handled = QOpenGLWidget::event(event);

    // This ensures that the OSG widget is always going to be repainted after the
    // user performed some interaction. Doing this in the event handler ensures
    // that we don't forget about some event and prevents duplicate code.
    switch (event->type())
    {
        case QEvent::Show:
            applyViewerHints();
            HeartBeat::start();
            // no break here
        case QEvent::KeyPress:
        case QEvent::KeyRelease:
        case QEvent::MouseButtonDblClick:
        case QEvent::MouseButtonPress:
        case QEvent::MouseButtonRelease:
        case QEvent::MouseMove:
        case QEvent::Wheel:
            view->requestRedraw();
            break;

        default:
            break;
    }

    return handled;
}

float OsgViewer::widgetAspectRatio() const
{
    return width() / (float)height();
}

void OsgViewer::setOsgCanvas(cOsgCanvas *canvas)
{
    if (osgCanvas != canvas) {
        osgCanvas = canvas;
        refresh();
        if (osgCanvas != nullptr) {
            applyViewerHints();
#ifdef WITH_OSGEARTH
            toEarthManipulatorAction->setEnabled(osgCanvas->getViewerStyle() == cOsgCanvas::STYLE_EARTH);
#endif
        }
        else
            resetViewer();

        getEventQueue()->clear();
    }
}

void OsgViewer::refresh()
{
    scene = osgCanvas ? osgCanvas->getScene() : nullptr;
    if (scene && scene != view->getSceneData()) {
        // otherwise textures vanish from all other views when one view is closed.
        osgUtil::Optimizer::TextureVisitor(true, false, false, false, false, false).apply(*scene);

        viewer->removeView(view);
        view->setSceneData(scene);
        viewer->addView(view);

#ifdef WITH_OSGEARTH
        auto sky = osgEarth::findTopMostNodeOfType<osgEarth::Util::SkyNode>(scene);
        if (sky)
            sky->attach(view);
#endif
    }
    view->requestRedraw();
}

void OsgViewer::applyViewerHints()
{
    ASSERT(osgCanvas != nullptr);

    cOsgCanvas::Color color = osgCanvas->getClearColor();
    setClearColor(color.red/255.0, color.green/255.0, color.blue/255.0, 1.0);

    setCameraManipulator(osgCanvas->getCameraManipulatorType());

    camera->setProjectionMatrixAsPerspective(30, 1, 1, 1000); // reset to sensible values to avoid later calls bump into a singular state

    setAspectRatio(widgetAspectRatio());
    setFieldOfViewAngle(osgCanvas->getFieldOfViewAngle());

    if (osgCanvas->hasZLimits()) {
        camera->setComputeNearFarMode(osg::CullSettings::DO_NOT_COMPUTE_NEAR_FAR);
        setZNearFar(osgCanvas->getZNear(), osgCanvas->getZFar());
    } else {
        camera->setComputeNearFarMode(defaultComputeNearFarMode);
    }

    view->requestRedraw();
}

void OsgViewer::resetViewer()
{
    // called when there is no cOsgCanvas to display
    ASSERT(osgCanvas == nullptr);
    setClearColor(0.9, 0.9, 0.9, 1.0);
    camera->setProjectionMatrixAsPerspective(30, 1, 1, 1000);

    view->requestRedraw();
}

void OsgViewer::uninit()
{
    HeartBeat::uninit();
    viewer = nullptr;
}

std::vector<cObject *> OsgViewer::objectsAt(const QPoint &pos)
{
    osgUtil::LineSegmentIntersector::Intersections intersections;
    view->computeIntersections(view->getCamera(), osgUtil::Intersector::WINDOW, pos.x(), height() - pos.y(), intersections);

    std::vector<cObject *> objects;
    for (osgUtil::LineSegmentIntersector::Intersections::iterator hitr = intersections.begin(); hitr != intersections.end(); ++hitr) {
        const osg::NodePath& nodePath = hitr->nodePath;
        // find cObject pointer node (OmnetppObjectNode) in nodepath, back to front
        for (int i = nodePath.size()-1; i >= 0; --i) {
            if (cObjectOsgNode *objNode = dynamic_cast<cObjectOsgNode*>(nodePath[i])) {
                if (cObject *obj = const_cast<cObject *>(objNode->getObject())) {
                    // qDebug() << "hit omnetpp object" << obj->getClassName() << obj->getFullPath().c_str();
                    if (std::find(objects.begin(), objects.end(), obj) == objects.end()) // filter out duplicates
                        objects.push_back(obj);
                }
            }
        }
    }
    return objects;
}

OsgViewer::~OsgViewer()
{
    viewer->removeView(view);
    view = nullptr;
    graphicsWindow->close(false);
}

unsigned int OsgViewer::mouseButtonQtToOsg(Qt::MouseButton button)
{
    switch (button) {
        case Qt::LeftButton:   return 1;
        case Qt::MiddleButton: return 2;
        case Qt::RightButton:  return 3;
        default:               return 0;
    }
}

void OsgViewer::setClearColor(float r, float g, float b, float alpha)
{
    camera->setClearColor(osg::Vec4(r, g, b, alpha));
}

void OsgViewer::setCameraManipulator(cOsgCanvas::CameraManipulatorType type, bool keepView)
{
    // saving the current viewpoint

    // all of these are in world coordinates, so expect large-values when using osgEarth
    osg::Vec3d eye, center, up;
    float distance = 1; // how far the center is from the eye.

    // all of the generic manipulators are OrbitManipulators
    if (auto orbitManip = dynamic_cast<osgGA::OrbitManipulator*>(view->getCameraManipulator()))
        distance = orbitManip->getDistance();

#ifdef WITH_OSGEARTH
    // EarthManipulator just happens to have a similar behaviour and a method with the same name
    if (auto earthManip = dynamic_cast<osgEarth::Util::EarthManipulator*>(view->getCameraManipulator()))
        distance = earthManip->getDistance();
#endif

    view->getCamera()->getViewMatrixAsLookAt(eye, center, up, distance);


    // setting up the new manipulator

    osgGA::CameraManipulator *manipulator = nullptr;

    if (type == cOsgCanvas::CAM_AUTO)
#ifdef WITH_OSGEARTH
        type = osgCanvas->getViewerStyle() == cOsgCanvas::STYLE_GENERIC ? cOsgCanvas::CAM_OVERVIEW : cOsgCanvas::CAM_EARTH;
#else
        type = cOsgCanvas::CAM_OVERVIEW;
#endif

    switch (type) {
        case cOsgCanvas::CAM_TERRAIN:
            manipulator = new osgGA::TerrainManipulator;
            toTerrainManipulatorAction->setChecked(true);
            break;
        case cOsgCanvas::CAM_OVERVIEW:
            manipulator = new OverviewManipulator;
            toOverviewManipulatorAction->setChecked(true);
            break;
        case cOsgCanvas::CAM_TRACKBALL:
            manipulator = new osgGA::TrackballManipulator;
            toTrackballManipulatorAction->setChecked(true);
            break;
#ifdef WITH_OSGEARTH
        case cOsgCanvas::CAM_EARTH:
            manipulator = new osgEarth::Util::EarthManipulator;
            toEarthManipulatorAction->setChecked(true);
            break;
#endif
        case cOsgCanvas::CAM_AUTO: /* Impossible, look at the if above, just silencing a warning. */ break;
    }

    view->setCameraManipulator(manipulator);


    // restoring the viewpoint into the new manipulator

    if (keepView) {
        if (auto orbitManip = dynamic_cast<osgGA::OrbitManipulator*>(manipulator)) {
            // this was the simplest way to force all kinds of manipulators to the viewpoint
            orbitManip->setHomePosition(eye, center, up);
            orbitManip->home(0);
            orbitManip->setDistance(distance);
        }

#ifdef WITH_OSGEARTH
        // and EarthManipulator is a different story as always
        if (auto earthManip = dynamic_cast<osgEarth::Util::EarthManipulator*>(manipulator)) {
            auto srs = osgEarth::MapNode::findMapNode(osgCanvas->getScene())->getMap()->getSRS();

            osg::Vec3d geoCenter; // should be longitude, latitude and absolute altitude
            srs->transformFromWorld(center, geoCenter);

            auto gc = osgEarth::GeoPoint(srs, geoCenter, osgEarth::ALTMODE_ABSOLUTE);
            // this transforms into a little local Descartian space around the point the camera is looking at
            osg::Matrixd worldToLocal;
            gc.createWorldToLocal(worldToLocal);

            // localCenter would be zero (even if imprecisely)
            osg::Vec3d localEye = eye * worldToLocal;
            osg::Vec3d localUp = (eye + up) * worldToLocal - localEye;

            double heading = - atan2(localEye.y(), localEye.x()) * 180.0 / M_PI - 90;
            double pitch = atan2(localUp.z(), osg::Vec2d(localUp.x(), localUp.y()).length()) * 180.0 / M_PI - 90;

            osgEarth::Viewpoint vp("viewpoint", geoCenter.x(), geoCenter.y(), geoCenter.z(), heading, pitch, distance);
            earthManip->setViewpoint(vp);
        }
#endif
    }


    // setting the home viewpoint if found

#ifdef WITH_OSGEARTH
    if (type == cOsgCanvas::CAM_EARTH) {
        const osgEarth::Viewpoint &homeViewpoint = osgCanvas->getEarthViewpoint();
        if (homeViewpoint.isValid())
            ((osgEarth::Util::EarthManipulator*)manipulator)->setHomeViewpoint(homeViewpoint);
    } else
#endif
    {
        const cOsgCanvas::Viewpoint &homeViewpoint = osgCanvas->getGenericViewpoint();
        if (homeViewpoint.valid)
            manipulator->setHomePosition(homeViewpoint.eye, homeViewpoint.center, homeViewpoint.up);
    }

    // and going home if needed
    if (!keepView)
        manipulator->home(0);
}

void OsgViewer::setFieldOfViewAngle(double fovy)
{
    double origFovy, origAspect, origZNear, origZFar;
    camera->getProjectionMatrixAsPerspective(origFovy, origAspect, origZNear, origZFar);
    camera->setProjectionMatrixAsPerspective(fovy, origAspect, origZNear, origZFar);
}

void OsgViewer::setAspectRatio(double aspectRatio)
{
    double origFovy, origAspect, origZNear, origZFar;
    camera->getProjectionMatrixAsPerspective(origFovy, origAspect, origZNear, origZFar);
    camera->setProjectionMatrixAsPerspective(origFovy, aspectRatio, origZNear, origZFar);
}

void OsgViewer::setZNearFar(double zNear, double zFar)
{
    double origFovy, origAspect, origZNear, origZFar;
    camera->getProjectionMatrixAsPerspective(origFovy, origAspect, origZNear, origZFar);
    camera->setProjectionMatrixAsPerspective(origFovy, origAspect, zNear, zFar);
}

QMenu *OsgViewer::createCameraManipulatorMenu()
{
    QMenu *menu = new QMenu("Camera manipulator", this);
    menu->addAction(toTerrainManipulatorAction);
    menu->addAction(toOverviewManipulatorAction);
    menu->addAction(toTrackballManipulatorAction);
#ifdef WITH_OSGEARTH
    menu->addAction(toEarthManipulatorAction);
#endif
    return menu;
}

void OsgViewer::setCameraManipulator(QAction *sender)
{
    setCameraManipulator((cOsgCanvas::CameraManipulatorType)sender->data().value<int>(), true);
}

void OsgViewer::resizeGL(int width, int height)
{
    getEventQueue()->windowResize(x(), y(), width, height);
    graphicsWindow->resized(x(), y(), width, height);
    camera->setViewport(0, 0, width, height);
}

osgGA::EventQueue* OsgViewer::getEventQueue() const
{
    return graphicsWindow->getEventQueue();
}

void OsgViewer::keyPressEvent(QKeyEvent *event)
{
    getEventQueue()->keyPress(osgGA::GUIEventAdapter::KeySymbol(event->key()), event->timestamp() / 1000.0);
}

void OsgViewer::keyReleaseEvent(QKeyEvent *event)
{
    getEventQueue()->keyRelease(osgGA::GUIEventAdapter::KeySymbol(event->key()), event->timestamp() / 1000.0);
}

void OsgViewer::mouseMoveEvent(QMouseEvent *event)
{
    getEventQueue()->mouseMotion(event->x() * widgetAspectRatio(), event->y(), event->timestamp() / 1000.0);
}

void OsgViewer::mousePressEvent(QMouseEvent *event)
{
    int osgButton = mouseButtonQtToOsg(event->button());
    if (event->type() == QEvent::MouseButtonDblClick)
        getEventQueue()->mouseDoubleButtonPress(event->x() * widgetAspectRatio(), event->y(), osgButton, event->timestamp() / 1000.0);
    else
        getEventQueue()->mouseButtonPress(event->x() * widgetAspectRatio(), event->y(), osgButton, event->timestamp() / 1000.0);

    if (event->button() == Qt::LeftButton) {
        auto objects = objectsAt(event->pos());
        if (!objects.empty()) {
            if (event->type() == QEvent::MouseButtonDblClick) {
                Inspector *insp = InspectorUtil::getContainingInspector(this);
                if (insp && insp->supportsObject(objects.front())) {
                    insp->setObject(objects.front());
                }
            } else {
                emit objectsPicked(objects);
            }
        }
    }

    if (event->button() == Qt::RightButton)
        lastRightClick = event->pos();
}

void OsgViewer::mouseReleaseEvent(QMouseEvent *event)
{
    getEventQueue()->mouseButtonRelease(event->x() * widgetAspectRatio(), event->y(), mouseButtonQtToOsg(event->button()), event->timestamp() / 1000.0);

    if (event->button() == Qt::RightButton
            && (lastRightClick - event->pos()).manhattanLength() < 3) {
        auto objects = objectsAt(event->pos());
        Inspector *insp = InspectorUtil::getContainingInspector(this);
        QMenu *menu;
        if (!objects.empty() && insp && insp->supportsObject(objects.front())) {
            menu = InspectorUtil::createInspectorContextMenu(QVector<cObject*>::fromStdVector(objects), insp);
            menu->addSeparator();
        } else {
            menu = new QMenu(this);
        }

        menu->addMenu(createCameraManipulatorMenu());
        menu->exec(event->globalPos());
    }
}

void OsgViewer::wheelEvent(QWheelEvent *event)
{
    // could also have used mouseScroll2D, but the camera
    // manipulators don't seem to respond to that

    // with smooth scrolling, we accumulate the many partial
    // scroll events into this, until we have a "full step" (120, 15 deg)
    static QPoint accum;

    // should really use angleDelta instead, since
    // orientation and delta are deprecated, but
    // no other way until we support Qt4
    switch (event->orientation()) {
        case Qt::Vertical:   accum.ry() += event->delta(); break;
        case Qt::Horizontal: accum.rx() += event->delta(); break;
    }

    // 120 represents 15 degrees, which is "one step" on most mice
    // see the Qt docs for details

    while (accum.y() >= 120) {
        getEventQueue()->mouseScroll(osgGA::GUIEventAdapter::SCROLL_UP, event->timestamp() / 1000.0);
        accum.ry() -= 120;
    }
    while (accum.y() <= -120) {
        getEventQueue()->mouseScroll(osgGA::GUIEventAdapter::SCROLL_DOWN, event->timestamp() / 1000.0);
        accum.ry() += 120;
    }

    while (accum.x() >= 120) {
        getEventQueue()->mouseScroll(osgGA::GUIEventAdapter::SCROLL_RIGHT, event->timestamp() / 1000.0);
        accum.rx() -= 120;
    }
    while (accum.x() <= -120) {
        getEventQueue()->mouseScroll(osgGA::GUIEventAdapter::SCROLL_LEFT, event->timestamp() / 1000.0);
        accum.rx() += 120;
    }
}

void OsgViewer::paintEvent(QPaintEvent *event)
{
    // Not doing anything here, painting is driven by the OSG event loop,
    // and the corresponding functions in the GraphicsWindow class above.
    // But we have to override this to be empty, otherwise the automatic
    // buffer swapping and such will interfere with viewer->frame().
}

} // qtenv
} // omnetpp

#endif // WITH_OSG
