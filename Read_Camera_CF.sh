#!/usr/local/bin/python

import os, sys, re
import shutil
import subprocess
import gpxpy
from datetime import datetime, tzinfo, timedelta

#
# Customize before using:
#

garmin_gps_volume = "/Volumes/GARMIN"
card_volume = "/Volumes/EOS_DIGITAL"
card_archive_folder = card_volume + "/archived"

dng_folder = "/Users/gbirkel/Pictures/DNG_RAW_In"	# For DNG files converted from CR2 files
gps_files_folder = "/Users/gbirkel/Documents/GPS"	# For GPX files from the GPS, to use for assigning geotags

exiftool = "/usr/local/bin/exiftool"
gpsbabel = "/usr/local/bin/gpsbabel"
dngconverter = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"


if not os.path.exists(dngconverter):
	print "Install the Adobe DNG converter, please."
	exit()
if not os.path.exists(exiftool):
	print "Install exiftool with \"brew install exiftool\", please."
	exit()
if not os.path.exists(gpsbabel):
	print "Install gpsbabel with \"brew install gpsbabel\", please."
	exit()
if not os.path.isdir(dng_folder):
	print "Cannot find file out path " + dng_folder + " ."
	exit()


# Support function to look for files on a given path
def look_for_files(p):
	try:
		ls_out = subprocess.check_output("ls " + p, shell=True)
		files_list = ls_out.split("\n")
		files_list = [f for f in files_list if len(f) > 4]
	except subprocess.CalledProcessError as e:
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


# Support function to invoke exiftool and pull out and parse three pieces of data:
# The creation date from the camera, the time zone currently set, and the active status of the GPS device in the camera while shooting.
def get_exif_bits_from_file(file_pathname):
	gps_stat_out = subprocess.check_output(
		exiftool + " -a -s -GPSStatus -TimeZone -SubSecCreateDate " + file_pathname, shell=True)
	exif_d = {}

	parts = gps_stat_out.split('SubSecCreateDate')
	date_and_time_tag = parts[1].strip(' \t\n\r:')
	d, t = date_and_time_tag.split(" ")
	df = re.sub(':', '-', d)
	tf = re.sub('[:\.]', '-', t)

	parts_b = parts[0].split('TimeZone')
	time_zone_tag = parts_b[1].strip(' \t\n\r:')

	# Parse the non-time-zone portion of the date string.
	# This is the easy part.
	# Most of the rest of this function is for taking the time zone into account.
	date_and_time_as_datetime = datetime.strptime(date_and_time_tag[:22], "%Y:%m:%d %H:%M:%S.%f")

	# This is where the difference in Canon firmware as mentioned in the README comes into play.

	# We will key off the length of the SubSecCreateDate tag to determine what to do.
	if len(date_and_time_tag) > 22:
		# Seems to have time zone info.  Isolate it so it works with our parser. 
		tz_to_parse = date_and_time_tag[22:]
	else:
		# Not long enough to have time zone info.  Use the TimeZone tag.
		tz_to_parse = time_zone_tag

	# Parse the time zone offset string into an offset in seconds
	# (Code adapted from dateutil.)
	tz_to_parse = tz_to_parse.strip()
	tz_as_offset = 0
	tz_without_modifier = tz_to_parse
	if tz_to_parse[0] in ('+', '-'):
		signal = (-1, +1)[tz_to_parse[0] == '+']
		tz_without_modifier = tz_to_parse[1:]
	else:
		signal = +1
	tz_without_modifier = re.sub(':', '', tz_without_modifier)
	if len(tz_without_modifier) == 4:
		tz_as_offset = (int(tz_without_modifier[:2])*3600 + int(tz_without_modifier[2:])*60) * signal
	elif len(s) == 6:
		tz_as_offset = (int(tz_without_modifier[:2])*3600 + int(tz_without_modifier[2:4])*60 + int(tz_without_modifier[4:])) * signal

	# Create an object of a tzinfo-derived class to hold the time zone info,
	# as required by datetime.
	tz_offset_tzinfo = fancytzoffset(tz_to_parse, tz_as_offset)

	# Replace the time zone info object with our own
	date_and_time_as_datetime = date_and_time_as_datetime.replace(tzinfo=tz_offset_tzinfo)

	has_gps = "Active" in gps_stat_out

	file_name = file_pathname.split('/')[-1]
	file_name_no_ext = ''.join(file_name.split('.')[0:-1])

	exif_d['date_as_str'] = df
	exif_d['date_and_time'] = df + " " + t
	exif_d['date_and_time_as_datetime'] = date_and_time_as_datetime
	exif_d['form_date'] = df + "_" + tf
	exif_d['has_gps'] = has_gps
	exif_d['file_name'] = file_name
	exif_d['file_name_no_ext'] = file_name_no_ext

	return exif_d


if os.path.exists(garmin_gps_volume):
	print "Found GPS path."
	#fit_files = look_for_files(garmin_gps_volume + "/Garmin/Activities/*.fit")	# Edge 500
	fit_files = look_for_files(garmin_gps_volume + "/Garmin/ACTIVITY/*.FIT")	# Edge 130
	if len(fit_files) > 0:
		for fit_file in fit_files:
			base_name = fit_file.split('/')[-1]
			base_name_no_ext = ''.join(base_name.split('.')[0:-1])
			print fit_file
			path_to_gpx = os.path.join(gps_files_folder, base_name_no_ext + '.gpx')
			gpsbabel_args = [
				'-i garmin_fit',		# Input format
				'-f',					# Input file
				fit_file,
				'-x track,pack,split=4h,title="LOG # %c"',	# Split activities if gap is larger than 4 hours
				'-o gpx',				# Output format
				'-F',					# Output file
				'"' + path_to_gpx + '"'
			]
			fit_convert_cmd = gpsbabel + " " + ' '.join(gpsbabel_args)
			fit_conv_out = subprocess.check_output(fit_convert_cmd, shell=True)
			mv_out = subprocess.check_output("mv \"" + fit_file + "\" \"" + fit_file + "-read\"", shell=True)
		print "Converted " + str(len(fit_files)) + " FIT files to GPX."


# If there is a card path, make sure the archive folder exists on it, and look for CR2 files.
if not os.path.isdir(card_volume):
	print "Cannot find card volume " + card_volume + " .  Skipping import stage."
	files_list = []
else:
	print "Found card path."
	# Make sure the archive folder on the card exists
	if not os.path.isdir(card_archive_folder):
		mkdir_out = subprocess.check_output("mkdir \"" + card_archive_folder + "\"", shell=True)
		if not os.path.isdir(card_archive_folder):
			print "Cannot create image archive path " + card_archive_folder + " ."
			exit()
		else:
			print "Created image archive path " + card_archive_folder + " ."

	# Look for CR2 files on the card
	files_list = look_for_files(card_volume + "/DCIM/*/*.CR2")
	if len(files_list) > 0:
		print "Found " + str(len(files_list)) + " CR2 files."
	else:
		print "No CR2 files found on card.  Skipping import stage."


# Save any target file EXIF data we read for later so we don't need to read it twice.
target_file_exif_data = {}

if len(files_list) > 0:

	all_exif_data = {}
	already_processed = []
	newly_processed = []

	for original in files_list:

		xf = get_exif_bits_from_file(original)

		target_file = xf['form_date'] + "_" + xf['file_name_no_ext'] + ".dng"

		xf['target_file_name'] = target_file
		xf['target_file_pathname'] = os.path.join(dng_folder, target_file)
		xf['gps_added'] = False

		# If the target file exists AND the datestamp in the EXIF matches exactly,
		# consider this file already processed.
		xf['target_exif'] = {}
		if not os.path.exists(xf['target_file_pathname']):
			xf['target_exists'] = False
			xf['already_converted'] = False
		else:
			txf = get_exif_bits_from_file(xf['target_file_pathname'])
			xf['target_exists'] = True
			xf['target_exif'] = txf
			xf['already_converted'] = xf['target_exif']['form_date'] == xf['form_date']
			# Save this for later so we don't have to read it twice
			target_file_exif_data[xf['target_file_pathname']] = txf

		if xf['has_gps']:
			has_gps_str = "   Has GPS "
		else:
			has_gps_str = "           "
		if xf['already_converted']:
			already_conv_str = "   Already Processed "
		else:
			already_conv_str = "                     "

		print xf['file_name_no_ext'] + ":   Date: " + pretty_datetime(xf['date_and_time_as_datetime']) + has_gps_str + already_conv_str

		if xf['already_converted']:
			already_processed.append(original)
		else:
			newly_processed.append(original)
			# DNG converter command line arguments
			conv_args = [
				'-c',		# Lossless compression
				'-p1',		# Medium preview
				'-fl',		# Fast-load data
				'-cr7.1',	# Camera Raw v7.1 and up compatible (works with Aperture)
				'-dng1.4',	# DNG file format 1.4 and up compatible (works with Aperture)
				'-d',		# Output directory
				"\"" + dng_folder + "\"",
				'-o',		# Output file
				"\"" + xf['target_file_name'] + "\"",
				"\"" + original + "\""	# Input file is last
			]

			# "open" command arguments, for launching the DNG converter.
			# -j : Launch the app hidden
			# -n : Open a new instance of the application even if one is already running
			# -W : Block and wait for the application to exit
			# -a : Path to application to open
			# --args : Everything beyond here should be passed to the application
			conv_command = "open -j -n -W -a \"" + dngconverter + "\" --args " + ' '.join(conv_args)

			dng_conv_output = subprocess.check_output(conv_command, shell=True)

			# Now there's a target file with the same EXIF data as the original,
			# So we save the EXIF data we pulled from the original under a reference to the target.
			target_file_exif_data[xf['target_file_pathname']] = xf

			archive_path = os.path.join(card_archive_folder, xf['date_as_str'])
			if not os.path.isdir(archive_path):
				os.makedirs(archive_path)

			archive_pathname = os.path.join(archive_path, xf['file_name'])
			print 'moving "' + original + '" to "' + archive_pathname + '"'
			shutil.move(original, archive_pathname)

		all_exif_data[original] = xf

	print "Already verified processed: " + str(len(already_processed))
	print "Newly Processed: " + str(len(newly_processed))
	to_move = already_processed + newly_processed
	print "Moved to archive folder: " + str(len(to_move))


# Look for DNG files in the target folder

dng_list = look_for_files(dng_folder + "/*.dng")
if len(dng_list) < 1:
	print "No DNG files found in target folder.  Skipping geotag stage."
	exit()
print "Found " + str(len(dng_list)) + " DNG files."

gpx_list = look_for_files(gps_files_folder + "/*.gpx")
if len(gpx_list) < 1:
	print "No GPX files found in gps log folder.  Skipping geotag stage."
	exit()
print "Found " + str(len(gpx_list)) + " GPX files."

# Fetch EXIF data for any DNGs that we haven't already
# (That would be all the DNGs that were in the target folder already
#  and didn't have filenames matching CR2s)
additional_exif_fetches = 0
for dng_file in dng_list:
	if not target_file_exif_data.has_key(dng_file):

		xf = get_exif_bits_from_file(dng_file)
		if xf['has_gps']:
			has_gps_str = "   Has GPS "
		else:
			has_gps_str = "           "
		print xf['file_name_no_ext'] + ":   Date: " + pretty_datetime(xf['date_and_time_as_datetime']) + has_gps_str

		target_file_exif_data[dng_file] = xf
		additional_exif_fetches = additional_exif_fetches + 1
if additional_exif_fetches > 0:
    print "Fetched EXIF data for an additional " + str(additional_exif_fetches) + " pre-existing DNG files."

# Filter out DNGs with valid GPS data in their EXIF tags.
dngs_without_gps = []
for dng_file in dng_list:
	if not target_file_exif_data[dng_file]['has_gps']:
		dngs_without_gps.append(dng_file)
if len(dngs_without_gps) < 1:
   	print "All DNG files have GPS tags.  Skipping geotag stage."
	exit()
print "Found " + str(len(dngs_without_gps)) + " DNG files without GPS data."

# Parse the GPX files to find their earliest timepoint and latest timepoint.
gpx_files_stats = {}
valid_gps_files = []
for gpx_file in gpx_list:
    earliest_start = datetime.max
    latest_end = datetime.min
    with open(gpx_file, 'r') as gpx_file_handle:
        gpx = gpxpy.parse(gpx_file_handle)
        for track in gpx.tracks:
			start_time, end_time = track.get_time_bounds()
			if start_time < earliest_start:
				earliest_start = start_time
			if end_time > latest_end:
				latest_end = end_time

	diags = ''
	# If the range looks funny, print a notice.  Otherwise, save the file and range in a dictionary.
	if earliest_start.year < 1980 or earliest_start.year > 2030 or latest_end.year < 1980 or latest_end.year > 2030:
		diags = "   (Bad range, won\'t use.)"
	else:
		stats = {}
		tz_utc = fancytzutc()
		earliest_start = earliest_start.replace(tzinfo=tz_utc)
		latest_end = latest_end.replace(tzinfo=tz_utc)
		# Create an object of a tzinfo-derived class to hold the time zone info,
		# as required by datetime.
		stats['start'] = earliest_start
		stats['end'] = latest_end
		gpx_files_stats[gpx_file] = stats
		valid_gps_files.append(gpx_file)

	print gpx_file + ":\t  Start: " + pretty_datetime(earliest_start) + "   End: " + \
            pretty_datetime(latest_end) + diags

if len(valid_gps_files) < 1:
   	print "No GPX files have valid date ranges.  Skipping geotag stage."
	exit()

for dng_file in dngs_without_gps:
	xf = target_file_exif_data[dng_file]	
	gpx_files_in_range = []
	for gpx_file in valid_gps_files:
		stats = gpx_files_stats[gpx_file]
		#if xf['']
    	



# TODO:  find compatible ranges, attempt tag


print "Done."
