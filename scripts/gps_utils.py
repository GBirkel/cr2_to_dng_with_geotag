import sys
import math
from datetime import datetime, tzinfo, timedelta
import gpxpy
from gpxpy.gpx import GPXTrackPoint

from common_utils import fancytzutc


def get_date_ranges_in_gpx_file(gpx_file):
	earliest_start = None
	latest_end = None
	with open(gpx_file, 'r') as gpx_file_handle:
		gpx = gpxpy.parse(gpx_file_handle)
		for track in gpx.tracks:
			start_time, end_time = track.get_time_bounds()
			if (earliest_start is None) or (start_time < earliest_start):
				earliest_start = start_time
			if (latest_end is None) or (end_time > latest_end):
				latest_end = end_time

	tz_utc = fancytzutc()
	earliest_start = earliest_start.replace(tzinfo=tz_utc)
	latest_end = latest_end.replace(tzinfo=tz_utc)
	return [earliest_start, latest_end]


def get_basic_points_from_gpx_file(gpx_file):
	all_gpx_points: list[BasicGpsPoint] = []
	prev_el = None
	prev_speed = None

	gpx = gpxpy.parse(open(gpx_file, 'r'))
	for _, track in enumerate(gpx.tracks):		
		for _, segment in enumerate(track.segments):
			for point_idx, point in enumerate(segment.points):
				p = {}
				tz_utc = fancytzutc()
				t_utc = point.time.replace(tzinfo=tz_utc)

				# Elevation and speed might be unset, so take them from the previous point, if one exists.
				if point.elevation is not None:
					elevation = point.elevation
					prev_el = point.elevation
				elif prev_el is not None:
					elevation = prev_el

				speed = segment.get_speed(point_idx)
				if speed is not None:
					prev_speed = speed
				elif prev_speed is not None:
					speed = prev_speed

				# If we could not set elevation or speed (if this is the 0th point) reject the point entirely.
				if (speed is None) or (elevation is None):
					continue

				p = BasicGpsPoint(
					time = t_utc,
					lat = point.latitude,
					lon = point.longitude,
					elevation = elevation,
					speed = speed,
					original_point = point
				)
				all_gpx_points.append(p)
	return all_gpx_points


class BasicGpsPoint:
	"""Basic data we accumulate about GPS points"""

	def __init__(
		self,
		time: datetime,
		lat: float,
		lon: float,
		elevation: float,
		speed: float,
		original_point: GPXTrackPoint
	):
		self.time = time
		self.lat = lat
		self.lon = lon
		self.elevation = elevation
		self.speed = speed
		self.original_point = original_point


# WGS-84 ellipsoid constants
WGS84_A = 6378137.0          # Semi-major axis (meters)
WGS84_F = 1 / 298.257223563  # Flattening
WGS84_E2 = WGS84_F * (2 - WGS84_F)  # Square of eccentricity


class GpsPointWithEcef(BasicGpsPoint):
	"""GPS points with ECEF coordinates"""

	def __init__(self, basic_point:BasicGpsPoint):
		super().__init__(
			time = basic_point.time,
			lat = basic_point.lat,
			lon = basic_point.lon,
			elevation = basic_point.elevation,
			speed = basic_point.speed,
			original_point = basic_point.original_point
		)

		alt_m = basic_point.elevation

		# Convert degrees to radians
		lat_rad = math.radians(basic_point.lat)
		lon_rad = math.radians(basic_point.lon)

		# Prime vertical radius of curvature
		N = WGS84_A / math.sqrt(1 - WGS84_E2 * math.sin(lat_rad)**2)

		# Calculate ECEF coordinates
		self.x = (N + alt_m) * math.cos(lat_rad) * math.cos(lon_rad)
		self.y = (N + alt_m) * math.cos(lat_rad) * math.sin(lon_rad)
		self.z = (N * (1 - WGS84_E2) + alt_m) * math.sin(lat_rad)


	def distance_from(self, other_point:'GpsPointWithEcef') -> float:
		"""Calculate the 3D distance in meters between this point and another point."""
		dx = self.x - other_point.x
		dy = self.y - other_point.y
		dz = self.z - other_point.z
		return math.sqrt(dx*dx + dy*dy + dz*dz)


class GpsLeg:
	"""A leg of a GPS track, which is a contiguous segment of points without large time or distance gaps"""

	def __init__(self, points:list[GpsPointWithEcef], supplemental:bool):
		self.points = points
		self.supplemental = supplemental
		self.identifier = points[0].time.isoformat()

		self.start_time = points[0].time
		self.end_time = points[-1].time
		self.duration_seconds = (self.end_time - self.start_time).total_seconds()

		prev_pt = None
		distance = 0.0
		for pt in points:
			if prev_pt is not None:
				distance += pt.distance_from(prev_pt)
			prev_pt = pt
		self.distance_meters = distance


	def make_reduced_version(self, minimum_distance = 5.0) -> 'GpsLeg':
		"""Make a reduced version of this leg, eliminating points that are less than minimum_distance meters from the previous point."""
		reduced_points = []
		previous_good_point = None

		for pt in self.points:
			if previous_good_point is None:
				previous_good_point = pt
				reduced_points.append(pt)
				continue

			distance = pt.distance_from(previous_good_point)

			if distance < minimum_distance:
				continue

			previous_good_point = pt
			reduced_points.append(pt)

		return GpsLeg(reduced_points, self.supplemental)


	def as_compact_json(self) -> dict:
		"""Turn this leg into a compact JSON format, breaking each type of data out into separate arrays to eliminate the redundant field names."""
		return {
			'identifier': self.identifier,
			'start_time': self.start_time.isoformat(),
			'end_time': self.end_time.isoformat(),
			'duration_seconds': self.duration_seconds,
			'distance_meters': self.distance_meters,
			't': [pt.time.isoformat() for pt in self.points],
			'lat': [pt.lat for pt in self.points],
			'lon': [pt.lon for pt in self.points],
			'el': [pt.elevation for pt in self.points],
			'spd': [pt.speed for pt in self.points]
		}
		

if __name__ == "__main__":
   sys.exit()
