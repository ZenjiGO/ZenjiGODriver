import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:geolocator/geolocator.dart';
import 'package:zenjigodriver/core/api/driver_api.dart';
import 'package:zenjigodriver/core/friendly_errors.dart';
import 'package:zenjigodriver/core/map/map_markers.dart';
import 'package:zenjigodriver/core/map/map_style.dart';
import 'package:zenjigodriver/core/map/map_widgets.dart';
import 'package:zenjigodriver/core/map/route_utils.dart';
import 'package:zenjigodriver/core/utils/directions_service.dart';

/// Professional live map for drivers — same road-following quality as the rider app.
///
/// - Google Routes API → OSRM fallback (never a silent straight line when roads exist)
/// - Dual glow + solid polylines along real roads
/// - Custom canvas markers (driver / pickup / drop-off / nearby riders)
/// - Styled dark / light map
class LiveDriverMap extends StatefulWidget {
  const LiveDriverMap({
    super.key,
    this.height = 320,
    this.showRequests = true,
    this.activeRideId,
    this.shareLocation = false,
    this.isSwahili = false,
    this.isDark = true,
  });

  final double height;
  final bool showRequests;
  final String? activeRideId;
  final bool shareLocation;
  final bool isSwahili;
  final bool isDark;

  @override
  State<LiveDriverMap> createState() => _LiveDriverMapState();
}

class _LiveDriverMapState extends State<LiveDriverMap> {
  gmaps.GoogleMapController? _controller;
  Position? _position;
  List<dynamic> _requests = [];
  Map<String, dynamic>? _ride;
  Timer? _locationTimer;
  Timer? _pollTimer;
  String? _mapError;
  bool _locationPermission = false;

  List<gmaps.LatLng> _routePoints = [];
  RouteResult? _routeMeta;
  List<gmaps.LatLng> _toPickupPoints = [];
  MapMarkerSet? _markers;
  bool _routeLoading = false;
  bool _didFitRoute = false; // fit the camera to the route once, then let the driver pan freely
  bool _centeredOnDriver = false;

  // Demand Radar (clear map by default; the driver can switch to the radar)
  bool _radarMode = false;
  bool _radarLoading = false;
  Map<String, dynamic>? _radar;
  Timer? _radarTimer;

  static const gmaps.LatLng _defaultCenter = gmaps.LatLng(-6.1659, 39.2026);

  String t(String en, String sw) => widget.isSwahili ? sw : en;

  @override
  void initState() {
    super.initState();
    _loadMarkers();
    _initLocation();
    _refreshRemote();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _refreshRemote());
    _locationTimer = Timer.periodic(const Duration(seconds: 10), (_) => _updateLocation());
  }

  @override
  void didUpdateWidget(covariant LiveDriverMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeRideId != widget.activeRideId) {
      if (widget.activeRideId != null && _radarMode) _setRadar(false);
      _didFitRoute = false;
      _routePoints = [];
      _toPickupPoints = [];
      _routeMeta = null;
    }
    if (oldWidget.activeRideId != widget.activeRideId ||
        oldWidget.showRequests != widget.showRequests ||
        oldWidget.shareLocation != widget.shareLocation) {
      _refreshRemote();
    }
    // Map style is applied via the `style` parameter on GoogleMap; rebuild handles theme changes.
  }

  Future<void> _loadMarkers() async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final set = await MapMarkers.load(ratio);
    if (mounted) setState(() => _markers = set);
  }

  Future<void> _initLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _mapError = t(
                'Allow location access to share your live position.',
                'Ruhusu eneo ili kushiriki nafasi yako moja kwa moja.',
              ));
        }
        return;
      }
      _locationPermission = true;
      await _updateLocation();
    } catch (e) {
      if (mounted) {
        setState(() => _mapError = FriendlyErrors.message(e, swahili: widget.isSwahili));
      }
    }
  }

  Future<void> _updateLocation() async {
    if (!_locationPermission) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;
      setState(() {
        _position = pos;
        _mapError = null;
      });
      if (!_centeredOnDriver && widget.activeRideId == null && _controller != null) {
        _centeredOnDriver = true;
        try {
          await _controller!.animateCamera(
            gmaps.CameraUpdate.newLatLngZoom(gmaps.LatLng(pos.latitude, pos.longitude), 15),
          );
        } catch (_) {}
      }
      if (widget.shareLocation || widget.activeRideId != null) {
        try {
          await DriverApi.updateLocation(
            pos.latitude,
            pos.longitude,
            heading: pos.heading.isFinite ? pos.heading : null,
            speed: pos.speed.isFinite ? pos.speed : null,
          );
        } catch (_) {}
        // Refresh driver→target road path when we move
        if (widget.activeRideId != null) {
          unawaited(_rebuildRoutes());
        }
      }
    } catch (_) {}
  }

  Future<void> _refreshRemote() async {
    try {
      if (widget.activeRideId != null) {
        final rideId = widget.activeRideId!;
        Map<String, dynamic>? found;
        try {
          // Prefer the dedicated ride endpoint (full coordinates + status).
          final detail = await DriverApi.ride(rideId);
          if (detail.isNotEmpty) found = detail;
        } catch (_) {}
        if (found == null) {
          // Fallback: scan recent history for a matching id.
          final result = await DriverApi.history(limit: 100);
          for (final item in result) {
            if (item is Map) {
              final candidate = Map<String, dynamic>.from(item);
              if ('${candidate['id'] ?? candidate['rideId'] ?? candidate['ride_id']}' == rideId) {
                found = candidate;
                break;
              }
            }
          }
        }
        if (mounted && found != null) {
          setState(() => _ride = found);
          await _rebuildRoutes();
        }
      } else if (widget.showRequests) {
        final result = await DriverApi.requests();
        final raw = result['requests'] ?? result['data'] ?? [];
        if (mounted) {
          setState(() => _requests = raw is List ? raw : []);
        }
      } else {
        if (mounted) setState(() => _requests = []);
      }
    } catch (_) {}
  }

  double? _num(dynamic value) {
    if (value is num && value.isFinite) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  Future<void> _rebuildRoutes() async {
    final ride = _ride;
    if (ride == null || widget.activeRideId == null) {
      if (mounted) {
        setState(() {
          _routePoints = [];
          _toPickupPoints = [];
          _routeMeta = null;
        });
      }
      return;
    }
    if (_routeLoading) return;
    _routeLoading = true;

    final pickupLat = _num(ride['pickupLat'] ?? ride['pickup_lat']);
    final pickupLng = _num(ride['pickupLng'] ?? ride['pickup_lng']);
    final destLat = _num(ride['destinationLat'] ?? ride['destination_lat']);
    final destLng = _num(ride['destinationLng'] ?? ride['destination_lng']);
    final status = '${ride['status'] ?? ''}'.toLowerCase();
    final pos = _position;

    try {
      // Full trip corridor: pickup → destination (road-following)
      if (pickupLat != null && pickupLng != null && destLat != null && destLng != null) {
        final trip = await DirectionsService.fetch(
          originLat: pickupLat,
          originLng: pickupLng,
          destLat: destLat,
          destLng: destLng,
        );
        if (mounted) {
          setState(() {
            _routePoints = GeoUtils.simplify(trip.points);
            _routeMeta = trip;
          });
        }
      }

      // Driver → next target (pickup while arriving, else destination)
      if (pos != null) {
        final goingToPickup = status.contains('accept') ||
            status.contains('arriv') ||
            status == 'assigned' ||
            status == 'searching';
        final tLat = goingToPickup ? pickupLat : destLat;
        final tLng = goingToPickup ? pickupLng : destLng;
        if (tLat != null && tLng != null) {
          final leg = await DirectionsService.route(
            originLat: pos.latitude,
            originLng: pos.longitude,
            destLat: tLat,
            destLng: tLng,
          );
          if (mounted) {
            setState(() => _toPickupPoints = GeoUtils.simplify(leg));
          }
        }
      }
      if (!_didFitRoute && (_routePoints.isNotEmpty || _toPickupPoints.isNotEmpty)) {
        _didFitRoute = true;
        await _fitBounds();
      }
    } finally {
      _routeLoading = false;
    }
  }

  Future<void> _fitBounds() async {
    final c = _controller;
    if (c == null) return;
    final pts = <gmaps.LatLng>[
      ..._routePoints,
      ..._toPickupPoints,
      ..._markerPositions,
    ];
    final bounds = GeoUtils.boundsOf(pts);
    if (bounds == null) return;
    try {
      await c.animateCamera(gmaps.CameraUpdate.newLatLngBounds(bounds, 56));
    } catch (_) {}
  }

  List<gmaps.LatLng> get _markerPositions {
    final out = <gmaps.LatLng>[];
    final pos = _position;
    if (pos != null) out.add(gmaps.LatLng(pos.latitude, pos.longitude));
    final ride = _ride;
    if (ride != null) {
      final plat = _num(ride['pickupLat'] ?? ride['pickup_lat']);
      final plng = _num(ride['pickupLng'] ?? ride['pickup_lng']);
      final dlat = _num(ride['destinationLat'] ?? ride['destination_lat']);
      final dlng = _num(ride['destinationLng'] ?? ride['destination_lng']);
      if (plat != null && plng != null) out.add(gmaps.LatLng(plat, plng));
      if (dlat != null && dlng != null) out.add(gmaps.LatLng(dlat, dlng));
    }
    return out;
  }

  Set<gmaps.Marker> get _mapMarkers {
    final markers = <gmaps.Marker>{};
    final icons = _markers;
    final pos = _position;
    if (pos != null) {
      markers.add(gmaps.Marker(
        markerId: const gmaps.MarkerId('driver'),
        position: gmaps.LatLng(pos.latitude, pos.longitude),
        infoWindow: gmaps.InfoWindow(title: t('You', 'Wewe')),
        icon: icons?.driverArrow ??
            gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueAzure),
        rotation: pos.heading.isFinite ? pos.heading : 0,
        flat: true,
        anchor: const Offset(0.5, 0.5),
        zIndexInt: 10,
      ));
    }

    if (widget.activeRideId != null && _ride != null) {
      final ride = _ride!;
      final pickupLat = _num(ride['pickupLat'] ?? ride['pickup_lat']);
      final pickupLng = _num(ride['pickupLng'] ?? ride['pickup_lng']);
      final destLat = _num(ride['destinationLat'] ?? ride['destination_lat']);
      final destLng = _num(ride['destinationLng'] ?? ride['destination_lng']);
      if (pickupLat != null && pickupLng != null) {
        markers.add(gmaps.Marker(
          markerId: const gmaps.MarkerId('pickup'),
          position: gmaps.LatLng(pickupLat, pickupLng),
          infoWindow: gmaps.InfoWindow(
            title: t('Pickup', 'Kuchukua'),
            snippet: '${ride['pickupAddress'] ?? ride['pickup_address'] ?? ''}',
          ),
          icon: icons?.pickup ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueGreen),
          anchor: const Offset(0.5, 0.92),
        ));
      }
      if (destLat != null && destLng != null) {
        markers.add(gmaps.Marker(
          markerId: const gmaps.MarkerId('destination'),
          position: gmaps.LatLng(destLat, destLng),
          infoWindow: gmaps.InfoWindow(
            title: t('Destination', 'Kwenda'),
            snippet: '${ride['destinationAddress'] ?? ride['destination_address'] ?? ''}',
          ),
          icon: icons?.destination ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
          anchor: const Offset(0.5, 0.92),
        ));
      }
    } else {
      for (var i = 0; i < _requests.length; i++) {
        final item = _requests[i];
        if (item is! Map) continue;
        final r = Map<String, dynamic>.from(item);
        final lat = _num(r['pickupLat'] ?? r['pickup_lat']);
        final lng = _num(r['pickupLng'] ?? r['pickup_lng']);
        if (lat == null || lng == null) continue;
        final id = '${r['id'] ?? i}';
        final type = '${r['rideType'] ?? r['ride_type'] ?? 'taxi'}';
        markers.add(gmaps.Marker(
          markerId: gmaps.MarkerId('request-$id'),
          position: gmaps.LatLng(lat, lng),
          infoWindow: gmaps.InfoWindow(
            title: t('Rider pickup', 'Abiria — kuchukua'),
            snippet:
                '${r['pickupAddress'] ?? r['pickup_address'] ?? ''} · $type',
          ),
          icon: icons?.nearbyFor(type) ??
              gmaps.BitmapDescriptor.defaultMarkerWithHue(gmaps.BitmapDescriptor.hueOrange),
          anchor: const Offset(0.5, 0.92),
        ));
      }
    }
    return markers;
  }

  Set<gmaps.Polyline> get _polylines {
    final set = <gmaps.Polyline>{};
    final isDark = widget.isDark;

    if (_routePoints.length >= 2) {
      set.addAll(MapUi.routeLine(
        id: 'trip',
        points: _routePoints,
        isDark: isDark,
      ));
    }
    if (_toPickupPoints.length >= 2) {
      // Active navigation leg — slightly brighter dashed overlay feel via second solid
      set.addAll(MapUi.routeLine(
        id: 'leg',
        points: _toPickupPoints,
        isDark: isDark,
        width: 5,
      ));
    }
    return set;
  }

  gmaps.LatLng get _center {
    final pos = _position;
    if (pos != null) return gmaps.LatLng(pos.latitude, pos.longitude);
    final ride = _ride;
    if (ride != null) {
      final lat = _num(ride['pickupLat'] ?? ride['pickup_lat']);
      final lng = _num(ride['pickupLng'] ?? ride['pickup_lng']);
      if (lat != null && lng != null) return gmaps.LatLng(lat, lng);
    }
    return _defaultCenter;
  }

  // ---- Demand Radar -----------------------------------------------------------------------------

  List<Map<String, dynamic>> get _zones {
    final z = _radar?['zones'];
    if (z is! List) return const [];
    return z.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _loadRadar() async {
    if (!_radarMode || _radarLoading) return;
    setState(() => _radarLoading = true);
    try {
      final pos = _position;
      final data = await DriverApi.demandZones(lat: pos?.latitude, lng: pos?.longitude);
      if (mounted && _radarMode) setState(() => _radar = data);
    } catch (e) {
      if (mounted) setState(() => _mapError = FriendlyErrors.message(e, swahili: widget.isSwahili));
    } finally {
      if (mounted) setState(() => _radarLoading = false);
    }
  }

  void _setRadar(bool on) {
    _radarTimer?.cancel();
    setState(() {
      _radarMode = on;
      if (!on) _radar = null;
    });
    if (on) {
      _loadRadar();
      _radarTimer = Timer.periodic(const Duration(seconds: 60), (_) => _loadRadar());
    }
  }

  static Color _zoneColor(double i) => i >= 0.75
      ? const Color(0xFFFF3D71)
      : i >= 0.5
          ? const Color(0xFFFF7A1A)
          : i >= 0.3
              ? const Color(0xFFFFB020)
              : const Color(0xFFFFD66B);

  /// Soft glow: three stacked translucent discs per zone, bigger and warmer where demand is higher.
  Set<gmaps.Circle> get _zoneCircles {
    if (!_radarMode) return const {};
    final out = <gmaps.Circle>{};
    var n = 0;
    for (final z in _zones) {
      final lat = _num(z['lat']);
      final lng = _num(z['lng']);
      final i = (_num(z['intensity']) ?? 0).clamp(0.0, 1.0);
      if (lat == null || lng == null) continue;
      final color = _zoneColor(i);
      const layers = [(1.0, 0.10), (0.66, 0.16), (0.36, 0.24)];
      for (var k = 0; k < layers.length; k++) {
        out.add(gmaps.Circle(
          circleId: gmaps.CircleId('z${n}_$k'),
          center: gmaps.LatLng(lat, lng),
          radius: (330 + 470 * i) * layers[k].$1,
          fillColor: color.withValues(alpha: layers[k].$2 * (0.6 + 0.6 * i)),
          strokeWidth: 0,
          zIndex: k,
        ));
      }
      n++;
    }
    return out;
  }

  String _dirName(num bearing) {
    final en = ['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'];
    final sw = ['kaskazini', 'kaskazini mashariki', 'mashariki', 'kusini mashariki', 'kusini', 'kusini magharibi', 'magharibi', 'kaskazini magharibi'];
    final idx = ((bearing / 45).round()) % 8;
    return widget.isSwahili ? sw[idx] : en[idx];
  }

  Widget _modeToggle() {
    final dark = widget.isDark;
    Widget seg(bool radar, IconData icon, String label) {
      final active = _radarMode == radar;
      final activeColor = radar ? const Color(0xFFFF5A3C) : const Color(0xFF0D9488);
      return GestureDetector(
        onTap: () => _setRadar(radar),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: active ? activeColor : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: active ? Colors.white : (dark ? Colors.white70 : Colors.black54)),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: active ? Colors.white : (dark ? Colors.white70 : Colors.black54),
                )),
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: MapUi.panelColor(dark),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(false, Icons.map_outlined, t('Clear', 'Wazi')),
        seg(true, Icons.radar_rounded, t('Radar', 'Rada')),
      ]),
    );
  }

  Widget _radarPanel() {
    final dark = widget.isDark;
    final fg = dark ? Colors.white : Colors.black87;
    final muted = dark ? Colors.white60 : Colors.black54;
    final period = _radar?['period'];
    final label = period is Map ? (period['label'] ?? '').toString() : '';
    final best = _radar?['best'];
    final building = (_radar?['confidence'] ?? '') == 'building';

    String headline;
    VoidCallback? go;
    if (_radar == null) {
      headline = t('Reading demand…', 'Inapima mahitaji…');
    } else if (best is Map) {
      final km = _num(best['distanceKm']) ?? 0;
      headline = km < 0.4
          ? t('You are in a busy zone', 'Uko katika eneo lenye abiria wengi')
          : t('Busiest: $km km ${_dirName(_num(best['bearing']) ?? 0)}', 'Pamoja zaidi: km $km ${_dirName(_num(best['bearing']) ?? 0)}');
      final bl = _num(best['lat']);
      final bg = _num(best['lng']);
      if (bl != null && bg != null) {
        go = () => _controller?.animateCamera(gmaps.CameraUpdate.newLatLngZoom(gmaps.LatLng(bl, bg), 15));
      }
    } else {
      headline = building
          ? t('Learning your area. Zones appear as riders book.', 'Tunajifunza eneo lako. Maeneo yataonekana abiria wakiomba.')
          : t('No busy areas right now', 'Hakuna eneo lenye shughuli sasa');
    }

    return GestureDetector(
      onTap: go,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        constraints: const BoxConstraints(maxWidth: 270),
        decoration: BoxDecoration(
          color: MapUi.panelColor(dark),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.local_fire_department_rounded, size: 16, color: Color(0xFFFF5A3C)),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label.isEmpty ? t('Demand Radar', 'Rada ya Mahitaji') : label,
                  style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
            ),
            if (_radarLoading) ...[
              const SizedBox(width: 8),
              const SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          const SizedBox(height: 4),
          Text(headline, style: TextStyle(color: muted, fontSize: 11.5, height: 1.25, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Row(children: [
              for (final c in const [Color(0xFFFFD66B), Color(0xFFFFB020), Color(0xFFFF7A1A), Color(0xFFFF3D71)])
                Expanded(child: Container(height: 6, color: c)),
            ]),
          ),
          const SizedBox(height: 3),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(t('Quiet', 'Kimya'), style: TextStyle(color: muted, fontSize: 9.5)),
            Text(t('Rider rush', 'Abiria wengi'), style: TextStyle(color: muted, fontSize: 9.5)),
          ]),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _radarTimer?.cancel();
    _locationTimer?.cancel();
    _pollTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    final mapHeight = widget.height.isFinite
        ? widget.height
        : (MediaQuery.sizeOf(context).height * 0.42).clamp(220.0, 480.0);
    final meta = _routeMeta;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: mapHeight,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            gmaps.GoogleMap(
              style: MapStyles.forBrightness(widget.isDark),
              initialCameraPosition: gmaps.CameraPosition(target: _center, zoom: 14.2),
              onMapCreated: (controller) async {
                _controller = controller;
                final pos = _position;
                if (widget.activeRideId == null && pos != null) {
                  _centeredOnDriver = true;
                  try {
                    await controller.animateCamera(
                      gmaps.CameraUpdate.newLatLngZoom(gmaps.LatLng(pos.latitude, pos.longitude), 15),
                    );
                  } catch (_) {}
                } else {
                  await _fitBounds();
                }
              },
              // The map lives inside a scrolling ListView: claim touch gestures so it can be
              // panned / zoomed instead of the list swallowing every drag.
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
              },
              markers: _mapMarkers,
              polylines: _polylines,
              circles: _zoneCircles,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: true,
              mapToolbarEnabled: false,
              trafficEnabled: false,
              buildingsEnabled: false,
              padding: EdgeInsets.only(bottom: 8 + bottomPad * 0.1, top: 8),
            ),
            if (widget.activeRideId == null)
              Positioned(right: 12, top: 12, child: _modeToggle()),
            if (_radarMode)
              Positioned(left: 12, top: 12, child: _radarPanel()),
            // Legend
            if (!_radarMode)
            Positioned(
              left: 12,
              top: 12,
              child: _Legend(
                isSwahili: widget.isSwahili,
                isDark: widget.isDark,
                showRoute: widget.activeRideId != null,
                showRiders: widget.showRequests && widget.activeRideId == null,
              ),
            ),
            // Route chip (distance / ETA) when we have a road path
            if (meta != null && meta.followsRoads)
              Positioned(
                left: 12,
                right: 64,
                bottom: 12,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: RouteInfoChip(
                    duration: meta.durationLabel,
                    distance: meta.distanceLabel,
                    isDark: widget.isDark,
                    approximate: false,
                  ),
                ),
              ),
            // Recenter
            Positioned(
              right: 12,
              bottom: 12,
              child: MapCircleButton(
                icon: Icons.my_location_rounded,
                isDark: widget.isDark,
                tooltip: t('My location', 'Eneo langu'),
                onTap: () async {
                  await _updateLocation();
                  final pos = _position;
                  if (pos != null && _controller != null) {
                    await _controller!.animateCamera(
                      gmaps.CameraUpdate.newLatLngZoom(
                        gmaps.LatLng(pos.latitude, pos.longitude),
                        15.5,
                      ),
                    );
                  } else {
                    await _fitBounds();
                  }
                },
              ),
            ),
            if (_mapError != null)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Material(
                  color: Colors.red.shade800.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Text(
                      _mapError!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.isSwahili,
    required this.isDark,
    required this.showRoute,
    required this.showRiders,
  });
  final bool isSwahili;
  final bool isDark;
  final bool showRoute;
  final bool showRiders;

  @override
  Widget build(BuildContext context) {
    final bg = MapUi.panelColor(isDark);
    final fg = isDark ? Colors.white70 : Colors.black87;
    String t(String en, String sw) => isSwahili ? sw : en;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(const Color(0xFF0D9488), t('You', 'Wewe')),
            if (showRoute) ...[
              const SizedBox(height: 4),
              _dot(const Color(0xFF22C55E), t('Pickup', 'Kuchukua')),
              const SizedBox(height: 4),
              _dot(const Color(0xFFF97316), t('Drop-off', 'Kushusha')),
            ],
            if (showRiders) ...[
              const SizedBox(height: 4),
              _dot(const Color(0xFFF59E0B), t('Nearby riders', 'Abiria karibu')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      );
}
