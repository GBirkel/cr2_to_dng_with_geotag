#!/usr/local/bin/python

import os, sys, re
import getopt
import shutil
import subprocess
import gpxpy
import json
import hashlib
from datetime import datetime, tzinfo, timedelta

#
# Customize before using:
#

garmin_gps_volume = "/Volumes/GARMIN"
#garmin_gps_volume = "/Users/gbirkel/Documents/Travel/GPS/Reprocess"
card_volume = "/Volumes/EOS_DIGITAL"

card_archive_folder = card_volume + "/archived"

# For DNG files converted from CR files
#dng_folder = "/Users/gbirkel/Pictures/DNG_RAW_In"
dng_folder = "/Users/gbirkel/Pictures/Lightroom_Auto_Import_Folder"

# For GPX files from the GPS, to use for assigning geotags
gps_files_folder = "/Users/gbirkel/Documents/Travel/GPS"
# For generating map+graph pages
chart_output_folder = "/Users/gbirkel/Documents/Travel/GPS"

# API to fetch short text comments for embedding in photos
api_seekrit = 'CHANGE THIS'
# Note that your camera's time must be set accurately, within a few seconds,
# to catch comments made just after shooting.
comment_fetch_url = "https://mile42.net/wp-json/ptws/v1/commentlog/unresolved"

exiftool = "/usr/local/bin/exiftool"
gpsbabel = "/usr/local/bin/gpsbabel"
dngconverter = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"


def check_all_paths():
	if not os.path.exists(dngconverter):
		print "Install the Adobe DNG converter, please."
		return False
	if not os.path.exists(exiftool):
		print "Install exiftool with \"brew install exiftool\", please."
		return False
	if not os.path.exists(gpsbabel):
		print "Install gpsbabel with \"brew install gpsbabel\", please."
		return False
	if not os.path.isdir(gps_files_folder):
		print "Cannot find gps_files_folder at: " + gps_files_folder + " ."
		return False
	if not os.path.isdir(chart_output_folder):
		print "Cannot find chart_output_folder folder at: " + chart_output_folder + " ."
		return False
	if not os.path.isdir(dng_folder):
		print "Cannot find dng_folder folder at: " + dng_folder + " ."
		return False
	return True


# Support function to look for files on a given path
def look_for_files(p):
	try:
		ls_out = subprocess.check_output("ls " + p, shell=True)
		files_list = ls_out.split("\n")
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


# Support function to fetch a set of recent short comments from a database
def get_recent_short_comments():
	curl_command = 'curl -F key=\"' + api_seekrit + '\" ' + comment_fetch_url
	fetch_out = '[]'
	try:
		fetch_out = subprocess.check_output(curl_command, shell=True)
	except subprocess.CalledProcessError:
		print "Error fetching recent comments!"

	exif_parsed = json.loads(fetch_out)
	all_comments = []

	for comment in exif_parsed:
		p = {}

		c = comment['composition_time'].encode('ascii','ignore')
		c_parsed = datetime.strptime(c, "%Y-%m-%d %H:%M:%S")
		# Assuming GMT.
		tz_offset_tzinfo = fancytzoffset('+00:00', 0)
		# Replace the time zone info object with our own
		c_parsed = c_parsed.replace(tzinfo=tz_offset_tzinfo)

		p['id'] = comment['id'].encode('ascii','ignore')
		p['content'] = comment['content'].encode('utf8','ignore')
		p['composition_time'] = c
		p['composition_time_parsed'] = c_parsed
					
		all_comments.append(p)

	return all_comments


# Support function to invoke exiftool and pull out and parse a collection of data,
# including the creation date from the camera, the time zone currently set,
# and the active status of the GPS device in the camera while shooting.
def get_exif_bits_from_file(file_pathname):
	exif_out = subprocess.check_output(
		exiftool + " -a -s -j " +
			"-GPSStatus -GPSPosition -TimeZone -OffsetTime -ImageSize -SubSecCreateDate -Description " +
			"-Source -SpecialInstructions -OriginalTransmissionReference " +
			file_pathname, shell=True)
	exif_parsed = json.loads(exif_out)
	exif_json = exif_parsed[0]
	results = {}

	date_and_time_tag = exif_json['SubSecCreateDate'].encode('ascii','ignore')

	d, t = date_and_time_tag.split(" ")
	df = re.sub(':', '-', d)
	tf = re.sub('[:\.]', '-', t)

	# Sometimes the fractions of a second has two decimal places (Canon), sometimes three (iPhone).
	time_parts = re.match('^([0-9]{2,4}\:[0-9]{2}\:[0-9]{2} [0-9]{2}\:[0-9]{2}\:[0-9]{2}\.[0-9]+)(.*)$', date_and_time_tag)
	date_and_time_without_tz = time_parts.group(1)
	possible_tz = time_parts.group(2)
	# Parse the non-time-zone portion of the date string.
	# This is the easy part.
	# Most of the rest of this function is for taking the time zone into account.
	date_and_time_as_datetime = datetime.strptime(date_and_time_without_tz, "%Y:%m:%d %H:%M:%S.%f")

	# Time zone parsing.  This is where the difference in Canon firmware as mentioned in the README comes into play.

	# We will key off the length of the SubSecCreateDate tag to determine what to do.
	if len(possible_tz) > 2:
		# Seems to have time zone info.  Isolate it so it works with our parser. 
		tz_to_parse = possible_tz
		found_tz = True
	elif 'TimeZone' in exif_json:
		# Not long enough to have time zone info.  Use the TimeZone tag.
		tz_to_parse = exif_json['TimeZone'].encode('ascii','ignore')
		found_tz = True
	elif 'OffsetTime' in exif_json:
		# Not long enough to have time zone info.  Use the OffsetTime tag.
		tz_to_parse = exif_json['OffsetTime'].encode('ascii','ignore')
		found_tz = True
	else:
		tz_to_parse = None
		found_tz = False

	tz_as_offset = 0
	if tz_to_parse:
		# Parse the time zone offset string into an offset in seconds
		# (Code adapted from dateutil.)
		tz_to_parse = tz_to_parse.strip()
		if tz_to_parse == 'Z':
			tz_to_parse = "+00:00"	# Manually translate UTC shorthand of Z into a time delta
		tz_without_modifier = tz_to_parse
		if tz_to_parse[0] in ('+', '-'):
			signal = (-1, +1)[tz_to_parse[0] == '+']
			tz_without_modifier = tz_to_parse[1:]
		else:
			signal = +1
		tz_without_modifier = re.sub(':', '', tz_without_modifier)
		if len(tz_without_modifier) == 4:
			tz_as_offset = (int(tz_without_modifier[:2])*3600 + int(tz_without_modifier[2:])*60) * signal
		elif len(tz_without_modifier) == 6:
			tz_as_offset = (int(tz_without_modifier[:2])*3600 + int(tz_without_modifier[2:4])*60 + int(tz_without_modifier[4:])) * signal

	# Create an object of a tzinfo-derived class to hold the time zone info,
	# as required by datetime.
	tz_offset_tzinfo = fancytzoffset(tz_to_parse, tz_as_offset)

	# Replace the time zone info object with our own
	date_and_time_as_datetime = date_and_time_as_datetime.replace(tzinfo=tz_offset_tzinfo)

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

	file_name = file_pathname.split('/')[-1]
	file_name_no_ext = ''.join(file_name.split('.')[0:-1])

	results['found_time_zone'] = found_tz
	results['date_as_str'] = df
	results['date_and_time'] = df + " " + t
	results['date_and_time_as_datetime'] = date_and_time_as_datetime
	results['form_date'] = df + "_" + tf

	results['has_gps'] = has_gps
	results['has_description'] = has_description
	results['image_dimensions'] = exif_json['ImageSize'].encode('ascii','ignore')

	results['source'] = source
	results['special_instructions'] = specinstructions
	results['transmission_reference'] = transmissionref

	results['file_name'] = file_name
	results['file_name_no_ext'] = file_name_no_ext

	return results


def main(argv):
	do_not_split_gpx = False
	try:
		opts, args = getopt.getopt(argv,"hg",["nosplitongaps"])
	except getopt.GetoptError:
		print 'Read_Camera_CF.sh -h for invocation help'
		sys.exit(2)
	for opt, arg in opts:
		if opt == '-h':
			print '-g or --nosplitongaps to turn off splitting of GPS data at 6-hour gaps'
			sys.exit()
		if opt in ("-g", "--nosplitongaps"):
			do_not_split_gpx = True

	if check_all_paths() == False:
		sys.exit()

	#
	# Phase 1: Import new FIT files from GPS device (and convert to GPX)
	#

	if os.path.exists(garmin_gps_volume):
		print "Found GPS path."
		e = look_for_files(garmin_gps_volume + "/Garmin/Activities/*.fit")	# Edge 500,530
		f = look_for_files(garmin_gps_volume + "/Garmin/ACTIVITY/*.FIT")	# Edge 130
		g = look_for_files(garmin_gps_volume + "/Garmin/Activity/*.fit")	# Edge 130+
		fit_files = e + f + g
		if len(fit_files) > 0:
			# We need to move these files off the drive or the 130 will simply rename them back to ".FIT",
			# causing them to be re-imported.
			archive_path = os.path.join(gps_files_folder, 'Processed')
			if not os.path.isdir(archive_path):
				os.makedirs(archive_path)

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
					'-o gpx,garminextensions=1',				# Output format GPX with Garmin extensions
					'-F',					# Output file
					'"' + path_to_gpx + '"'
				]
				fit_convert_cmd = gpsbabel + " " + ' '.join(gpsbabel_args)
				fit_conv_out = subprocess.check_output(fit_convert_cmd, shell=True)
				# If we use move, MacOS will attempt to copy file permissions.
				# On Garmin devices, FIT files are shown with permissions of 777.
				# Since the executable permission is set, MacOS will try to apply that, which will fail due to system protection measures.
				# Trying to change the permissions on the source file in place will have no result.
				# So we use copyfile instead, which does not attempt to set equivalent permissions, then remove the source file afterwards.
				shutil.copyfile(fit_file, os.path.join(archive_path, base_name))
				os.remove(fit_file)
			print "Converted " + str(len(fit_files)) + " FIT files to GPX."

	#
	# Phase 2: Import new CR files from camera card device (and convert to DNG)
	#

	# If there is a card path, make sure the archive folder exists on it, and look for CR files.
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

		# Look for CR files on the card
		files_list = look_for_files(card_volume + "/DCIM/*/*.CR2") + look_for_files(card_volume + "/DCIM/*/*.CR3")
		if len(files_list) > 0:
			print "Found " + str(len(files_list)) + " CR files."
		else:
			print "No CR files found on card.  Skipping import stage."

	# Save any target file EXIF data we read for later so we don't need to read it twice.
	target_file_exif_data = {}

	if len(files_list) > 0:

		all_exif_data = {}
		already_processed = []
		newly_processed = []

		for original in files_list:

			exif_bits = get_exif_bits_from_file(original)

			target_file = exif_bits['form_date'] + "_" + exif_bits['file_name_no_ext'] + ".dng"

			exif_bits['target_file_name'] = target_file
			exif_bits['target_file_pathname'] = os.path.join(dng_folder, target_file)
			exif_bits['gps_added'] = False

			# If the target file exists AND the datestamp in the EXIF matches exactly,
			# consider this file already processed.
			exif_bits['target_exif'] = {}
			if not os.path.exists(exif_bits['target_file_pathname']):
				exif_bits['target_exists'] = False
				exif_bits['already_converted'] = False
			else:
				texif_bits = get_exif_bits_from_file(exif_bits['target_file_pathname'])
				exif_bits['target_exists'] = True
				exif_bits['target_exif'] = texif_bits
				exif_bits['already_converted'] = exif_bits['target_exif']['form_date'] == exif_bits['form_date']
				# Save this for later so we don't have to read it twice
				target_file_exif_data[exif_bits['target_file_pathname']] = texif_bits

			if exif_bits['has_gps']:
				has_gps_str = "   Has GPS "
			else:
				has_gps_str = "           "
			if exif_bits['already_converted']:
				already_conv_str = "   Already Processed "
			else:
				already_conv_str = "                     "

			print exif_bits['file_name_no_ext'] + ":   Date: " + pretty_datetime(exif_bits['date_and_time_as_datetime']) + has_gps_str + already_conv_str

			if exif_bits['already_converted']:
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
					"\"" + exif_bits['target_file_name'] + "\"",
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
				target_file_exif_data[exif_bits['target_file_pathname']] = exif_bits

				archive_path = os.path.join(card_archive_folder, exif_bits['date_as_str'])
				if not os.path.isdir(archive_path):
					os.makedirs(archive_path)

				archive_pathname = os.path.join(archive_path, exif_bits['file_name'])
				print 'moving "' + original + '" to "' + archive_pathname + '"'
				shutil.move(original, archive_pathname)

			all_exif_data[original] = exif_bits

		print "Already verified processed: " + str(len(already_processed))
		print "Newly Processed: " + str(len(newly_processed))
		to_move = already_processed + newly_processed
		print "Moved to archive folder: " + str(len(to_move))

	#
	# Phase 2-b: Locate pre-existing DNG / HEIC files and read their EXIF tags as well
	#

	dng_list = look_for_files(dng_folder + "/*.dng")
	if len(dng_list) < 1:
			print "No DNG files found in target folder."
	else:
		print "Found " + str(len(dng_list)) + " DNG files."

		# Fetch EXIF data for any DNGs that we haven't already
		# (That would be all the DNGs that were in the target folder already
		#  and didn't have filenames matching CRs)
		additional_exif_fetches = 0
		for dng_file in dng_list:
			if not target_file_exif_data.has_key(dng_file):

				exif_bits = get_exif_bits_from_file(dng_file)
				if exif_bits['has_gps']:
					has_gps_str = "   Has GPS "
				else:
					has_gps_str = "           "
				print exif_bits['file_name_no_ext'] + ":   Date: " + pretty_datetime(exif_bits['date_and_time_as_datetime']) + has_gps_str

				target_file_exif_data[dng_file] = exif_bits
				additional_exif_fetches = additional_exif_fetches + 1
		if additional_exif_fetches > 0:
			print "Fetched EXIF data for an additional " + str(additional_exif_fetches) + " pre-existing DNG files."

	heic_list = look_for_files(dng_folder + "/*.HEIC")
	if len(heic_list) > 0:
		print "Found " + str(len(heic_list)) + " HEIC files."

		additional_exif_fetches = 0
		for heic_file in heic_list:
			exif_bits = get_exif_bits_from_file(heic_file)
			if exif_bits['has_gps']:
				has_gps_str = "   Has GPS "
			else:
				has_gps_str = "           "
			print exif_bits['file_name_no_ext'] + ":   Date: " + pretty_datetime(exif_bits['date_and_time_as_datetime']) + has_gps_str

			target_file_exif_data[heic_file] = exif_bits
			additional_exif_fetches = additional_exif_fetches + 1
		if additional_exif_fetches > 0:
			print "Fetched EXIF data for an additional " + str(additional_exif_fetches) + " pre-existing HEIC files."

	#
	# Phase 3: Ensure that a reasonably unique identifier is embedded in all found photos
	#

	found_list = dng_list + heic_list
	if len(found_list) < 1:
		print "Skipping unique ID stage."
	else:
		print "Starting unique ID stage."
		# Filter out images with content in their SpecialInstructions EXIF tags.
		images_without_ids = []
		for image_file in found_list:
			if not target_file_exif_data[image_file]['special_instructions']:
				images_without_ids.append(image_file)
		if len(images_without_ids) < 1:
			print "All image files have unique ID tags.  Skipping unique ID stage."
		else:
			print "Found " + str(len(images_without_ids)) + " image files without unique IDs."

			for image_file in images_without_ids:
				exif_bits = target_file_exif_data[image_file]

				hash_id_object = exif_bits['file_name'] + exif_bits['form_date'] + exif_bits['image_dimensions']
				calcualted_hash = hashlib.md5(hash_id_object.encode())
				hash_id_string = calcualted_hash.hexdigest()

				exif_id_embed_args = [
					'-overwrite_original',
					'-SpecialInstructions="' + hash_id_string + '"',
					'"' + image_file + '"'
				]
				# For some reason this fails on HEIC images.  Not sure why.
				exif_id_embed_cmd = exiftool + " " + ' '.join(exif_id_embed_args)
				exif_id_embed_out = subprocess.check_output(exif_id_embed_cmd, shell=True)

	#
	# Phase 4: Fetch a list of recent short comments from the Poking Things With Sticks blog
	#          and embed them in any photos that are a reasonable timestamp match.

	if len(found_list) < 1:
		print "Skipping comment embed stage."
	else:
		print "Starting comment embed stage."
		# Filter out DNGs with valid GPS data in their EXIF tags.
		images_without_comments = []
		for image_file in found_list:
			if not target_file_exif_data[image_file]['has_description']:
				images_without_comments.append(image_file)
		if len(images_without_comments) < 1:
			print "All DNG files have embedded comments.  Skipping comment embed stage."
		else:
			print "Found " + str(len(images_without_comments)) + " DNG files without comments."
			comments_to_consider = get_recent_short_comments()
			if len(comments_to_consider) < 1:
				print "No un-paired comments to consider.  Skipping comment embed stage."
			else:
				print "Found " + str(len(comments_to_consider)) + " comments to consider."

				comments_by_id = {}
				for c in comments_to_consider:
					comments_by_id[c['id']] = c

				# Step 1: Determine which photo is closest in time to each comment
				# without being after, and note the interval.
				# Ignore any gaps larger than 20 minutes.
				time_scores = {}
				for c in comments_to_consider:
					smallest_interval = {}
					for image_file in images_without_comments:
						exif_bits = target_file_exif_data[image_file]
						comment_delta = c['composition_time_parsed'] - exif_bits['date_and_time_as_datetime']
						score = comment_delta.total_seconds()
						if score > 0 and score < 1200:
							if 'image_file' in smallest_interval:
								if score < smallest_interval['interval']:
									smallest_interval['image_file'] = image_file
									smallest_interval['interval'] = score
							else:
								smallest_interval['image_file'] = image_file
								smallest_interval['interval'] = score
					time_scores[c['id']] = smallest_interval
				# Step 2: Find the photos that are closest to multiple comments,
				# and eliminate all but the closest comment.
				photo_scores = {}
				for c in comments_to_consider:
					current_comment_id = c['id']
					time_score = time_scores[current_comment_id]
					if 'image_file' in time_score:
						present_image_file = time_score['image_file']
						if present_image_file in photo_scores:
							old_comment_id = photo_scores[present_image_file]
							if time_score['interval'] < time_scores[old_comment_id]['interval']:
								photo_scores[present_image_file] = current_comment_id
						else:
							photo_scores[present_image_file] = current_comment_id
				# We are left with:
				# Zero or one comment assigned to each photo,
				# Zero or one photo assigned to each comment.
				# Assignments only where the photo is older, but not older than 20 minutes.
				for image_file in images_without_comments:
					if image_file in photo_scores:
						assigned_comment = comments_by_id[photo_scores[image_file]]
						exif_bits = target_file_exif_data[image_file]

						c = assigned_comment['content']
						print exif_bits['file_name_no_ext'] + ":  " + c
						c_formatted = re.sub('"', "'", c)

						exif_embed_args = [
							'-Description="' + c_formatted + '"',
							'"' + image_file + '"'
						]
						exif_embed_cmd = exiftool + " " + ' '.join(exif_embed_args)
						exif_embed_out = subprocess.check_output(exif_embed_cmd, shell=True)

	#
	# Phase 5: Locate and parse all GPX files in working folder (from this or previous sessions)
	#

	gpx_list = look_for_files(gps_files_folder + "/*.gpx")
	if len(gpx_list) < 1:
		print "No GPX files found in gps log folder.  Skipping geotag stage."
		exit()
	print "Found " + str(len(gpx_list)) + " GPX files."

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

	# The plan here is to read all the data points from all the valid GPX files at once,
	# then use the nearest points before and after a photo timestamp to find the relevant point for that photo.
	# Of course, if we've somehow recorded two tracks for the same time period in very different locations,
	# this will make a mess.  But this is a single-user script and that situation is beyond the design spec.

	all_gpx_points = []
	prev_el = None
	prev_speed = None

	for gpx_file in valid_gps_files:
		gpx = gpxpy.parse(open(gpx_file, 'r'))
		for track_idx, track in enumerate(gpx.tracks):		
			for seg_idx, segment in enumerate(track.segments):
				segment_length = segment.length_3d()
				for point_idx, point in enumerate(segment.points):
					p = {}
					tz_utc = fancytzutc()
					t_utc = point.time.replace(tzinfo=tz_utc)
					p['t'] = t_utc
					p['lat'] = point.latitude
					p['lon'] = point.longitude
					p['el'] = point.elevation
					p['spd'] = segment.get_speed(point_idx)
					p['op'] = point
					
					# Elevation and speed might be unset, so take them from the previous point, if one exists.
					if p['el'] is not None:
						prev_el = p['el']
					elif prev_el is not None:
						p['el'] = prev_el
					if p['spd'] is not None:
						prev_speed = p['spd']
					elif prev_speed is not None:
						p['spd'] = prev_speed

					# If we could not set elevation or speed (if this is the 0th point) reject the point entirely.
					if (p['spd'] is not None) and (p['el'] is not None):
						all_gpx_points.append(p)
						last_point = p

	print "Sorting " + str(len(all_gpx_points)) + " GPX points."

	sorted_gpx_points = sorted(all_gpx_points, key=lambda x: x['t'], reverse=False)

	#
	# Phase 6: Examine all DNG files without GPS tags, and tag them if possible.
	#

	if len(dng_list) < 1:
		print "Skipping geotag stage."
	else:
		print "Starting geotag stage."
		# Filter out DNGs with valid GPS data in their EXIF tags.
		dngs_without_gps = []
		for dng_file in dng_list:
			if not target_file_exif_data[dng_file]['has_gps']:
				dngs_without_gps.append(dng_file)
		if len(dngs_without_gps) < 1:
			print "All DNG files have GPS tags.  Skipping geotag stage."
		else:
			print "Found " + str(len(dngs_without_gps)) + " DNG files without GPS data."

			for dng_file in dngs_without_gps:
				exif_bits = target_file_exif_data[dng_file]
				photo_dt = exif_bits['date_and_time_as_datetime']
				i = 0
				found_highpoint = False
				while i < len(sorted_gpx_points) and not found_highpoint:
					if sorted_gpx_points[i]['t'] > photo_dt:
						found_highpoint = True
					else:
						i += 1
				found_midpoint = False

				# To ensure a decent GPS read, we want a
				# location that has at least two points on either side,
				# each within 20 seconds of its neighbors.
				if i > 1 and i < (len(sorted_gpx_points)-1):
					found_midpoint = True
				if not found_midpoint:
					print exif_bits['file_name_no_ext'] + ": No points within range."
				else:
					photo_time_delta = photo_dt - sorted_gpx_points[i-1]['t']

					gap = timedelta(seconds=20)
					delta_during = sorted_gpx_points[i]['t'] - sorted_gpx_points[i-1]['t']
					delta_before = sorted_gpx_points[i-1]['t'] - sorted_gpx_points[i-2]['t']
					delta_after = sorted_gpx_points[i+1]['t'] - sorted_gpx_points[i]['t']
					if delta_during > gap or delta_before > gap or delta_after > gap:
						print exif_bits['file_name_no_ext'] + ": Falls on a gap larger than 20 seconds."
					else:

						# In GPX files, latitude and longitude are supplied as decimal degrees
						# and are allowed a negative range, e.g. -180 to 180 for longitude.

						# Calculate the delta for the latitude, longitude, and elevation.
						lat_start = sorted_gpx_points[i-1]['lat']
						lon_start = sorted_gpx_points[i-1]['lon']
						el_start = sorted_gpx_points[i-1]['el']
						lat_delta = sorted_gpx_points[i]['lat'] - lat_start
						lon_delta = sorted_gpx_points[i]['lon'] - lon_start
						el_delta = sorted_gpx_points[i]['el'] - el_start

						# Find a mid-point for the photo, interpolating based on the time.
						lat_calc = sorted_gpx_points[i-1]['lat']
						lon_calc = sorted_gpx_points[i-1]['lon']
						el_calc = sorted_gpx_points[i-1]['el']
						time_delta_s = delta_during.total_seconds()
						photo_time_delta_s = photo_time_delta.total_seconds()
						# If the interval, or the offset from the start point, are zero, just take the start point.
						if photo_time_delta_s > 0 and time_delta_s > 0:
							frac = time_delta_s / photo_time_delta_s
							lat_calc = lat_start + (frac * lat_delta)
							lon_calc = lon_start + (frac * lon_delta)
							el_calc = el_start + (frac * el_delta)

						# When supplying this data to the EXIF tool we will have to take the absolute
						# value, and provide a "reference" for whether that value is forward or backward:
						# For latitude: "North" for a positive original value,
						#               versus "South" for a negative original value.
						# For longitude: "East" versus "West"
						# For elevation: "Above Sea Level" versus "Below Sea Level", expressed in meters.

						lat_ref_str = "North"
						if lat_calc < 0:
							lat_ref_str = "South"
						long_ref_str = "East"
						if lon_calc < 0:
							long_ref_str = "West"
						el_ref = "Above Sea Level"
						if el_calc < 0:
							el_ref = "Below Sea Level"

						print exif_bits['file_name_no_ext'] + ":  Lat " + str(abs(lat_calc)) + " " + lat_ref_str + "   Lon " + \
								str(abs(lon_calc)) + " " + long_ref_str + "   Alt " + str(abs(el_calc)) + " " + el_ref

						exif_gps_embed_args = [
							'-GPSLatitude="' + str(abs(lat_calc)) + '"',
							'-GPSLongitude="' + str(abs(lon_calc)) + '"',
							'-GPSAltitude="' + str(abs(el_calc)) + ' m"',
							'-GPSLatitudeRef="' + lat_ref_str + '"',
							'-GPSLongitudeRef="' + long_ref_str + '"',
							'-GPSAltitudeRef="' + el_ref + '"',
							'-GPSStatus="Measurement Active"',
							'"' + dng_file + '"'
						]
						exif_gps_embed_cmd = exiftool + " " + ' '.join(exif_gps_embed_args)
						exif_gps_embed_out = subprocess.check_output(exif_gps_embed_cmd, shell=True)

	#
	# Phase 7: Use current stock of GPX data to generate embeddable data for an inline google map
	#          and an inline jsChart, broken across gaps in recording larger than six hours

	# The "larger than six hour break" rule is needed because the beginning and ending of each day
	# will change based on the time zone, so breaking across days is cumbersome, especially
	# if the rider rides past midnight.

	template_file_h = open("route_template.html", "r")
	template_html = template_file_h.read()

	if not os.path.isdir(chart_output_folder):
		print "Cannot find chart output path " + chart_output_folder + " ."
		exit()

	# Break all our GPX data into continuous chunks defined by gaps larger than six hours between them.

	continuous_ranges = []
	if do_not_split_gpx:
		smallest_allowable_gap = timedelta(hours=60000)
	else:
		smallest_allowable_gap = timedelta(hours=6)

	this_range_start = 0
	prev_time = sorted_gpx_points[0]['t']
	i = 1

	while i < len(sorted_gpx_points):
		cur_time = sorted_gpx_points[i]['t']
		time_delta = cur_time - prev_time
		# If the gap betewen this point and the last is larger than 6 hours, declare a new range
		if time_delta > smallest_allowable_gap:
			# Runs less than 60 samples are ignored
			if (i - this_range_start) > 60:
				new_range = {}
				new_range['start'] = this_range_start
				new_range['end'] = i-1
				continuous_ranges.append(new_range)
			this_range_start = i
		prev_time = cur_time
		i += 1
	if i > 1:
		if (i - this_range_start) > 60:
			new_range = {}
			new_range['start'] = this_range_start
			new_range['end'] = i-1
			continuous_ranges.append(new_range)
	print "Found " + str(len(continuous_ranges)) + " continuous ranges."

	# Turn each range into a minimal JSON data format, breaking each type of data out
	# into separate arrays to eliminate the redundant field names.

	chart_out_path = os.path.join(chart_output_folder, 'route_gallery.html')
	json_out_path = os.path.join(chart_output_folder, 'route_gallery.json')

	cofh = open(chart_out_path, "w")
	cofh.write(template_html)

	gallery_json = []

	for r in continuous_ranges:
		lat = []
		lon = []
		el = []
		t = []
		t_quoted = []
		spd = []
		i = r['start']
		while i <= r['end']:
			pt = sorted_gpx_points[i]
			lat.append(str(pt['lat']))
			lon.append(str(pt['lon']))
			el.append(str(pt['el']))
			t.append(pt['t'].isoformat())
			t_quoted.append('"' + pt['t'].isoformat() + '"')
			spd.append(str(pt['spd']))
			i += 1
		
		range_identifier = t[0]
		if do_not_split_gpx:
			range_identifier = range_identifier.split('T')[0] + "-notsplit"

		cofh.write("<div class='ptws-ride-log' rideid=" + '"' + range_identifier + '"' + ">\n<div class='data'>\n")

		range_json_str = "{\n" + \
						'"lat":[' + ','.join(lat) + "],\n" + \
						'"lon":[' + ','.join(lon) + "],\n" + \
						'"el":[' + ','.join(el) + "],\n" + \
						'"t":[' + ','.join(t_quoted) + "],\n" + \
						'"spd":[' + ','.join(spd) + "]\n" + \
						"}\n"

		# We write this JSON structure out twice:
		# Once in the HTML file to display the routes in a gallery,
		cofh.write(range_json_str)
		cofh.write("</div>\n</div>\n")
		# and once in a JSON file that we use as reference material for uploading the routes to the web
		gallery_json.append([range_identifier, range_json_str])

	cofh.write("\n</body>\n</html>")
	cofh.close()

	gallery_json_obj = {}
	gallery_json_obj['a'] = gallery_json
	with open(json_out_path, 'w') as json_out_handle:
		json.dump(gallery_json_obj, json_out_handle)

	print "Done."


if __name__ == "__main__":
   main(sys.argv[1:])
