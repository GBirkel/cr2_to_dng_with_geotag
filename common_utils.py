import os, sys, re
import codecs
import shutil
import subprocess
import json, xml.dom.minidom
import hashlib
from datetime import datetime, tzinfo, timedelta


# Read in the standard configuration file and return its parsed contents
def read_config():
	config = {}
	if os.access("config.xml", os.F_OK):
		config_xml = xml.dom.minidom.parse("config.xml")
		for item in config_xml.documentElement.childNodes:
			if item.nodeType == item.ELEMENT_NODE:
				config[item.tagName] = item.firstChild.data
		return config
	else:
		return None


# Support function to look for files on a given path
def look_for_files(p):
	try:
		ls_out = subprocess.check_output("ls " + p, shell=True)
		ls_out_str = codecs.utf_8_decode(ls_out)[0]
		files_list = ls_out_str.split("\n")
		files_list = [f for f in files_list if len(f) > 4]
	except subprocess.CalledProcessError:
		files_list = []
	return files_list


# Subclass of tzinfo swiped mostly from dateutil
class fancytzoffset(tzinfo):
    def __init__(self, name, offset):
        self._name = name
        self._offset = timedelta(seconds=offset)
    def utcoffset(self, dt):
        return self._offset
    def dst(self, dt):
        return timedelta(0)
    def tzname(self, dt):
        return self._name
    def __eq__(self, other):
        return (isinstance(other, fancytzoffset) and self._offset == other._offset)
    def __ne__(self, other):
        return not self.__eq__(other)
    def __repr__(self):
        return "%s(%s, %s)" % (self.__class__.__name__,
                               repr(self._name),
                               self._offset.days*86400+self._offset.seconds)
    __reduce__ = object.__reduce__


# Variant tzinfo subclass for UTC pulled from GPX logs
class fancytzutc(tzinfo):
    def utcoffset(self, dt):
        return timedelta(0)
    def dst(self, dt):
        return timedelta(0)
    def tzname(self, dt):
        return "UTC"
    def __eq__(self, other):
        return (isinstance(other, fancytzutc) or
                (isinstance(other, fancytzoffset) and other._offset == timedelta(0)))
    def __ne__(self, other):
        return not self.__eq__(other)
    def __repr__(self):
        return "%s()" % self.__class__.__name__
    __reduce__ = object.__reduce__


# Support function to pretty-print dates that datetime can't handle
def pretty_datetime(t):
	# Code loosely adapted from Perl's HTTP-Date
	MoY = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec']
	mon = t.month - 1
	date_str = '%04d-%s-%02d' % (t.year, MoY[mon], t.day)
	hour = t.hour
	half_day = 'am'
	if hour > 11:
		half_day = 'pm'
	if hour > 12:
		hour = hour - 12
	elif hour == 0:
		hour = 12
	u = t.tzname()
	u_str = ''
	if u is not None:
		u_str = ' ' + u
	time_str = '%02d:%02d%s' % (hour, t.minute, half_day)

	return date_str + ' ' + time_str + u_str


# Support function to invoke exiftool and pull out and parse a collection of data,
# including the creation date from the camera, the time zone currently set,
# and the active status of the GPS device in the camera while shooting.
def get_exif_bits_from_file(exiftool, file_pathname):
	exif_out = subprocess.check_output(
		exiftool + " -a -s -j " +
			"-GPSStatus -GPSPosition -TimeZone -OffsetTime -ImageSize -SubSecCreateDate -Description " +
			"-Source -SpecialInstructions -OriginalTransmissionReference -DateTimeOriginal " +
			file_pathname, shell=True)
	exif_out_str = codecs.utf_8_decode(exif_out)[0]
	exif_parsed = json.loads(exif_out_str)
	exif_json = exif_parsed[0]
	results = {}

	source = None
	if 'Source' in exif_json:
		source = exif_json['Source']
	specinstructions = None
	if 'SpecialInstructions' in exif_json:
		specinstructions = exif_json['SpecialInstructions']
	transmissionref = None
	if 'OriginalTransmissionReference' in exif_json:
		transmissionref = exif_json['OriginalTransmissionReference']

	has_gps = False
	if 'GPSStatus' in exif_json:
		if 'Active' in exif_json['GPSStatus']:
			has_gps = True
	elif 'GPSPosition' in exif_json:
		if ',' in exif_json['GPSPosition']:
			has_gps = True

	has_description = False
	if 'Description' in exif_json:
		has_description = True
		results['description'] = exif_json['Description']
	results['has_description'] = has_description

	file_name = file_pathname.split('/')[-1]
	file_name_no_ext = ''.join(file_name.split('.')[0:-1])

	results['has_gps'] = has_gps
	results['image_dimensions'] = str(exif_json['ImageSize'])

	results['source'] = source
	results['special_instructions'] = specinstructions
	results['transmission_reference'] = transmissionref

	results['file_name'] = file_name
	results['file_name_no_ext'] = file_name_no_ext

	#
	# Try to properly handle the time and time zone
	#

	date_and_time_tag = None


	if 'SubSecCreateDate' in exif_json:
		date_and_time_tag = exif_json['SubSecCreateDate']
	elif 'DateTimeOriginal' in exif_json:
		date_and_time_tag = exif_json['DateTimeOriginal']

	if date_and_time_tag == None:
		results['has_creation_date'] = False
		return results

	d, t = date_and_time_tag.split(u' ')
	df = re.sub(':', '-', d)
	tf = re.sub('[:\.]', '-', t)
	# Sometimes the fractions of a second has two decimal places (Canon), sometimes three (iPhone),
	# and sometimes it's entirely missing (Lightroom).
	found_fractions_of_second = True
	time_parts = re.match('^([0-9]{2,4}\:[0-9]{2}\:[0-9]{2} [0-9]{2}\:[0-9]{2}\:[0-9]{2}\.[0-9]+)(.*)$', date_and_time_tag)
	if time_parts is None:
		# Catch the 'entirely missing' case
		found_fractions_of_second = False
		time_parts = re.match('^([0-9]{2,4}\:[0-9]{2}\:[0-9]{2} [0-9]{2}\:[0-9]{2}\:[0-9]{2})(.*)$', date_and_time_tag)
	date_and_time_without_tz = time_parts.group(1)
	possible_tz = time_parts.group(2)
	# Parse the non-time-zone portion of the date string.
	# This is the easy part.
	# Most of the rest of this function is for taking the time zone into account.
	if found_fractions_of_second:
		date_and_time_as_datetime = datetime.strptime(date_and_time_without_tz, "%Y:%m:%d %H:%M:%S.%f")
	else:
		date_and_time_as_datetime = datetime.strptime(date_and_time_without_tz, "%Y:%m:%d %H:%M:%S")

	# Time zone parsing.  This is where the difference in Canon firmware as mentioned in the README comes into play.

	# We will key off the length of the SubSecCreateDate tag to determine what to do.
	if len(possible_tz) > 2:
		# Seems to have time zone info.  Isolate it so it works with our parser. 
		tz_to_parse = possible_tz
		found_tz = True
	elif 'TimeZone' in exif_json:
		# Not long enough to have time zone info.  Use the TimeZone tag.
		tz_to_parse = exif_json['TimeZone']
		found_tz = True
	elif 'OffsetTime' in exif_json:
		# Not long enough to have time zone info.  Use the OffsetTime tag.
		tz_to_parse = exif_json['OffsetTime']
		found_tz = True
	else:
		tz_to_parse = None
		found_tz = False

	tz_as_offset = 0
	if tz_to_parse:
		# Parse the time zone offset string into an offset in seconds
		# (Code adapted from dateutil.)
		tz_to_parse = tz_to_parse.strip()
		if tz_to_parse == u'Z':
			tz_to_parse = u'+00:00'	# Manually translate UTC shorthand of Z into a time delta
		tz_without_modifier = tz_to_parse
		if tz_to_parse[0] in (u'+', u'-'):
			signal = (-1, +1)[tz_to_parse[0] == u'+']
			tz_without_modifier = tz_to_parse[1:]
		else:
			signal = +1
		tz_without_modifier = re.sub(u':', u'', tz_without_modifier)
		if len(tz_without_modifier) == 4:
			tz_as_offset = (int(tz_without_modifier[:2])*3600 + int(tz_without_modifier[2:])*60) * signal
		elif len(tz_without_modifier) == 6:
			tz_as_offset = (int(tz_without_modifier[:2])*3600 + int(tz_without_modifier[2:4])*60 + int(tz_without_modifier[4:])) * signal

	# Create an object of a tzinfo-derived class to hold the time zone info,
	# as required by datetime.
	tz_offset_tzinfo = fancytzoffset(tz_to_parse, tz_as_offset)

	# Replace the time zone info object with our own
	date_and_time_as_datetime = date_and_time_as_datetime.replace(tzinfo=tz_offset_tzinfo)

	results['found_time_zone'] = found_tz
	results['date_as_str'] = df
	results['date_and_time'] = df + " " + t
	results['date_and_time_as_datetime'] = date_and_time_as_datetime
	results['form_date'] = df + "_" + tf

	results['has_creation_date'] = True

	return results


if __name__ == "__main__":
   sys.exit()
