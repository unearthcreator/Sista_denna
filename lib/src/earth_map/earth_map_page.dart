import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // for rootBundle
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

// ---------------------- External & Project Imports ----------------------
import 'package:map_mvp_project/repositories/local_annotations_repository.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' show CameraChangedEventData;
import 'package:map_mvp_project/services/error_handler.dart';
import 'package:map_mvp_project/src/earth_map/annotations/map_annotations_manager.dart';
import 'package:map_mvp_project/src/earth_map/gestures/map_gesture_handler.dart';
import 'package:map_mvp_project/src/earth_map/utils/map_config.dart';
import 'package:uuid/uuid.dart'; // for unique IDs
import 'package:map_mvp_project/src/earth_map/timeline/timeline.dart';
import 'package:map_mvp_project/src/earth_map/annotations/annotation_id_linker.dart';
import 'package:map_mvp_project/models/world_config.dart';
import 'package:map_mvp_project/src/earth_map/search/search_widget.dart';
import 'package:map_mvp_project/src/earth_map/misc/test_utils.dart';
import 'package:map_mvp_project/src/earth_map/utils/connect_banner.dart';
import 'package:map_mvp_project/src/earth_map/annotations/annotation_menu.dart';

// 1. Import your new actions class
import 'package:map_mvp_project/src/earth_map/annotations/annotation_actions.dart';

/// The main EarthMapPage, which sets up the map, annotations, and various UI widgets.
class EarthMapPage extends StatefulWidget {
  final WorldConfig worldConfig;

  const EarthMapPage({Key? key, required this.worldConfig}) : super(key: key);

  @override
  EarthMapPageState createState() => EarthMapPageState();
}

class EarthMapPageState extends State<EarthMapPage> {
  // ---------------------- Map-Related Variables ----------------------
  late MapboxMap _mapboxMap;
  late MapAnnotationsManager _annotationsManager;
  late MapGestureHandler _gestureHandler;
  late LocalAnnotationsRepository _localRepo;
  bool _isMapReady = false;

  // ---------------------- Timeline / Canvas UI ----------------------
  List<String> _hiveUuidsForTimeline = [];
  bool _showTimelineCanvas = false;

  // ---------------------- Annotation Menu Variables ----------------------
  bool _showAnnotationMenu = false;
  PointAnnotation? _annotationMenuAnnotation;
  Offset _annotationMenuOffset = Offset.zero;

  // ---------------------- Dragging & Connect Mode ----------------------
  bool _isDragging = false;
  bool _isConnectMode = false;
  String get _annotationButtonText => _isDragging ? 'Lock' : 'Move';

  // ---------------------- UUID Generator ----------------------
  final uuid = Uuid();

  // Keep a reference to your new AnnotationActions
  late AnnotationActions _annotationActions;

  @override
  void initState() {
    super.initState();
    logger.i('Initializing EarthMapPage');
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ---------------------------------------------------------------------
  //                       MAP CREATION / INIT
  // ---------------------------------------------------------------------
  Future<void> _onMapCreated(MapboxMap mapboxMap) async {
    try {
      logger.i('Starting map initialization');
      _mapboxMap = mapboxMap;

      // Create the annotation manager
      final annotationManager = await mapboxMap.annotations
          .createPointAnnotationManager()
          .onError((error, stackTrace) {
        logger.e('Failed to create annotation manager', error: error, stackTrace: stackTrace);
        throw Exception('Failed to initialize map annotations');
      });

      _localRepo = LocalAnnotationsRepository();
      final annotationIdLinker = AnnotationIdLinker();

      _annotationsManager = MapAnnotationsManager(
        annotationManager,
        annotationIdLinker: annotationIdLinker,
        localAnnotationsRepository: _localRepo,
      );

      _gestureHandler = MapGestureHandler(
        mapboxMap: _mapboxMap,
        annotationsManager: _annotationsManager,
        context: context,
        localAnnotationsRepository: _localRepo,
        annotationIdLinker: annotationIdLinker,
        onAnnotationLongPress: _handleAnnotationLongPress,
        onAnnotationDragUpdate: _handleAnnotationDragUpdate,
        onDragEnd: _handleDragEnd,
        onAnnotationRemoved: _handleAnnotationRemoved,
        onConnectModeDisabled: () {
          setState(() {
            _isConnectMode = false;
          });
        },
      );

      // Initialize your new AnnotationActions instance
      _annotationActions = AnnotationActions(
        localRepo: _localRepo,
        annotationsManager: _annotationsManager,
        annotationIdLinker: annotationIdLinker,
      );

      logger.i('Map initialization completed successfully');

      if (mounted) {
        setState(() => _isMapReady = true);
        await _annotationsManager.loadAnnotationsFromHive();
      }
    } catch (e, stackTrace) {
      logger.e('Error during map initialization', error: e, stackTrace: stackTrace);
      if (mounted) {
        setState(() {});
      }
    }
  }

  // ---------------------------------------------------------------------
  //                LISTEN FOR CAMERA CHANGES -> MENU "STICKS"
  // ---------------------------------------------------------------------
  void _onCameraChangeListener(CameraChangedEventData data) {
    _updateMenuPositionIfNeeded();
  }

  Future<void> _updateMenuPositionIfNeeded() async {
    if (_annotationMenuAnnotation != null && _showAnnotationMenu) {
      final geo = _annotationMenuAnnotation!.geometry;
      final realScreenPos = await _mapboxMap.pixelForCoordinate(geo);
      setState(() {
        _annotationMenuOffset = Offset(realScreenPos.x + 15, realScreenPos.y - 42);
      });
    }
  }

  // ---------------------------------------------------------------------
  //               ANNOTATION UI & CALLBACKS
  // ---------------------------------------------------------------------
  void _handleAnnotationLongPress(PointAnnotation annotation, Point annotationPosition) async {
    // If a menu is already open, ignore new annotation presses
    if (_showAnnotationMenu) {
      logger.i('Ignoring new annotation press; menu is already open');
      return;
    }

    final screenPos = await _mapboxMap.pixelForCoordinate(annotationPosition);
    setState(() {
      _annotationMenuAnnotation = annotation;
      _showAnnotationMenu = true;
      _annotationMenuOffset = Offset(screenPos.x + 15, screenPos.y - 42);
    });
  }

  void _handleAnnotationDragUpdate(PointAnnotation annotation) async {
    final screenPos = await _mapboxMap.pixelForCoordinate(annotation.geometry);
    setState(() {
      _annotationMenuAnnotation = annotation;
      _annotationMenuOffset = Offset(screenPos.x + 15, screenPos.y - 42);
    });
  }

  void _handleDragEnd() {
    logger.i('Drag ended');
  }

  void _handleAnnotationRemoved() {
    setState(() {
      _showAnnotationMenu = false;
      _annotationMenuAnnotation = null;
      _isDragging = false;
    });
  }

  // ---------------------------------------------------------------------
  // LONG PRESS HANDLERS
  // ---------------------------------------------------------------------
  void _handleLongPress(LongPressStartDetails details) async {
    try {
      logger.i('Long press started at: ${details.localPosition}');
      final screenPoint = ScreenCoordinate(
        x: details.localPosition.dx,
        y: details.localPosition.dy,
      );

      // 1) If the annotation menu is currently open, we do NOT create a new annotation
      //    or open a new one. We skip everything.
      if (_showAnnotationMenu) {
        logger.i('Menu is open, ignoring long press => no new annotation creation');
        return;
      }

      // 2) If we’re in MOVE mode, check if user pressed the same annotation
      if (_isDragging) {
        final mapPoint = await _mapboxMap.coordinateForPixel(screenPoint);
        final nearestAnn = await _annotationsManager.findNearestAnnotation(mapPoint);

        if (nearestAnn == _annotationMenuAnnotation) {
          _gestureHandler.handleLongPress(screenPoint);
        } else {
          logger.i('Ignoring long press => different annotation or empty space');
        }
        return;
      }

      // 3) Otherwise => normal logic (create annotation or open menu)
      _gestureHandler.handleLongPress(screenPoint);

    } catch (e, stackTrace) {
      logger.e('Error handling long press', error: e, stackTrace: stackTrace);
    }
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) async {
    try {
      if (_isDragging) {
        final screenPoint = ScreenCoordinate(
          x: details.localPosition.dx,
          y: details.localPosition.dy,
        );
        final mapPoint = await _mapboxMap.coordinateForPixel(screenPoint);
        final nearestAnn = await _annotationsManager.findNearestAnnotation(mapPoint);

        if (nearestAnn == _annotationMenuAnnotation) {
          _gestureHandler.handleDrag(screenPoint);
        } else {
          logger.i('User is dragging on different location => ignoring');
        }
      }
    } catch (e, stackTrace) {
      logger.e('Error handling drag update', error: e, stackTrace: stackTrace);
    }
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    try {
      logger.i('Long press ended');
      if (_isDragging) {
        _gestureHandler.endDrag();
      }
    } catch (e, stackTrace) {
      logger.e('Error handling long press end', error: e, stackTrace: stackTrace);
    }
  }

  // ---------------------------------------------------------------------
  // MENU BUTTON CALLBACKS
  // ---------------------------------------------------------------------
  void _handleMoveOrLockButton() {
    setState(() {
      if (_isDragging) {
        _gestureHandler.hideTrashCanAndStopDragging();
        _isDragging = false;
      } else {
        _gestureHandler.startDraggingSelectedAnnotation();
        _isDragging = true;
      }
    });
  }

  Future<void> _handleEditButton() async {
    if (_annotationMenuAnnotation == null) {
      logger.w('No annotation selected to edit.');
      return;
    }

    await _annotationActions.editAnnotation(
      context: context,
      mapAnnotation: _annotationMenuAnnotation!,
    );

    setState(() {});
  }

  void _handleConnectButton() {
    logger.i('Connect button clicked');
    setState(() {
      _showAnnotationMenu = false;
      if (_isDragging) {
        _gestureHandler.hideTrashCanAndStopDragging();
        _isDragging = false;
      }
      _isConnectMode = true;
    });
    if (_annotationMenuAnnotation != null) {
      _gestureHandler.enableConnectMode(_annotationMenuAnnotation!);
    } else {
      logger.w('No annotation available when Connect pressed');
    }
  }

  void _handleCancelButton() {
    setState(() {
      _showAnnotationMenu = false;
      _annotationMenuAnnotation = null;
      if (_isDragging) {
        _gestureHandler.hideTrashCanAndStopDragging();
        _isDragging = false;
      }
    });
  }

  // ---------------------------------------------------------------------
  // BUILD MAP + OVERLAYS
  // ---------------------------------------------------------------------
  Widget _buildMapWidget() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: _handleLongPress,
      onLongPressMoveUpdate: _handleLongPressMoveUpdate,
      onLongPressEnd: _handleLongPressEnd,
      onLongPressCancel: () {
        logger.i('Long press cancelled');
        if (_isDragging) {
          _gestureHandler.endDrag();
        }
      },
      child: MapWidget(
        cameraOptions: MapConfig.defaultCameraOptions,
        styleUri: MapConfig.styleUriEarth,
        onMapCreated: _onMapCreated,
        onCameraChangeListener: _onCameraChangeListener,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          _buildMapWidget(),

          if (_isMapReady) ...[
            buildTimelineButton(
              isMapReady: _isMapReady,
              context: context,
              mapboxMap: _mapboxMap,
              annotationsManager: _annotationsManager,
              onToggleTimeline: () {
                setState(() {
                  _showTimelineCanvas = !_showTimelineCanvas;
                });
              },
              onHiveIdsFetched: (List<String> hiveIds) {
                setState(() {
                  _hiveUuidsForTimeline = hiveIds;
                });
              },
            ),
            buildClearAnnotationsButton(annotationsManager: _annotationsManager),
            buildClearImagesButton(),
            buildDeleteImagesFolderButton(),
            EarthMapSearchWidget(
              mapboxMap: _mapboxMap,
              annotationsManager: _annotationsManager,
              gestureHandler: _gestureHandler,
              localRepo: _localRepo,
              uuid: uuid,
            ),
            // The annotation menu is above the map, so ensure these clicks pass.
            AnnotationMenu(
              show: _showAnnotationMenu,
              annotation: _annotationMenuAnnotation,
              offset: _annotationMenuOffset,
              isDragging: _isDragging,
              annotationButtonText: _annotationButtonText,
              onMoveOrLock: _handleMoveOrLockButton,
              onEdit: _handleEditButton,
              onConnect: _handleConnectButton,
              onCancel: _handleCancelButton,
            ),
            buildConnectModeBanner(
              isConnectMode: _isConnectMode,
              gestureHandler: _gestureHandler,
              onCancel: () {
                setState(() {
                  _isConnectMode = false;
                });
              },
            ),
            buildTimelineCanvas(
              showTimelineCanvas: _showTimelineCanvas,
              hiveUuids: _hiveUuidsForTimeline,
            ),
          ],
        ],
      ),
    );
  }
}