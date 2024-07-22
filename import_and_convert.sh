#!/Applications/Xcode.app/Contents/Developer/usr/bin/python3

import os, sys, re
import getopt
import codecs
import shutil
import subprocess
import gpxpy
import json
import hashlib
from common_utils import *
from datetime import datetime, tzinfo, timedelta

#
# Customize config.xml before using!
#


def check_all_paths(config):
	if not os.path.exists(config['dngconverter']):
		print("Install the Adobe DNG converter, please.")
		return False
	if not os.path.exists(config['exiftool']):
		print("Install exiftool with \"brew install exiftool\", please.")
		return False
	if not os.path.exists(config['gpsbabel']):
		print("Install gpsbabel with \"brew install gpsbabel\", please.")
		return False
	if not os.path.isdir(config['gps_files_folder']):
		print("Cannot find gps_files_folder at: " + config['gps_files_folder'] + " .")
		return False
	if not os.path.isdir(config['chart_output_folder']):
		print("Cannot find chart_output_folder folder at: " + config['chart_output_folder'] + " .")
		return False
	if not os.path.isdir(config['dng_folder']):
		print("Cannot find dng_folder folder at: " + config['dng_folder'] + " .")
		return False
	return True


# Support function to fetch a set of recent short comments from a database
def get_recent_short_comments(config):
	curl_command = 'curl -F key=\"' + config['api_seekrit'] + '\" ' + config['comment_fetch_url']
	fetch_out_str = '[]'
	try:
		fetch_out = subprocess.check_output(curl_command, shell=True)
		fetch_out_str = codecs.utf_8_decode(fetch_out)[0]
	except subprocess.CalledProcessError:
		print("Error fetching recent comments!")

	exif_parsed = json.loads(fetch_out)
	all_comments = []

	for comment in exif_parsed:
		p = {}

		c = comment['composition_time']
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


def main(argv):
	do_not_split_gpx = False
	replace_gps = False
	try:
		opts, args = getopt.getopt(argv,"hgr",["nosplitongaps", "replacegps"])
	except getopt.GetoptError:
		print('Read_Camera_CF.sh -h for invocation help')
		sys.exit(2)
	for opt, arg in opts:
		if opt == '-h':
			print('-g or --nosplitongaps to turn off splitting of GPS data at 4-hour gaps')
			print('-r or --replacegps to overwrite existing GPS data where new data is found')
			sys.exit()
		if opt in ("-g", "--nosplitongaps"):
			do_not_split_gpx = True
		if opt in ("-r", "--replacegps"):
			replace_gps = True

	config = read_config()
	if config is None:
		print('Error reading your config.xml file!')
		sys.exit(2)

	local_cr_archive_folder = config['local_cr_folder'] + "/processed"
	card_archive_folder = config['card_volume'] + "/archived"

	time_offset_for_photo_locations = timedelta(seconds=int(config['time_offset_for_photo_locations']))
	altitude_offset_for_photo_locations = float(config['altitude_offset_for_photo_locations'])


	if check_all_paths(config) == False:
		sys.exit()

	#
	# Phase 1: Import new FIT files from GPS device (and convert to GPX)
	#

	if os.path.exists(config['garmin_gps_volume']):
		print("Found GPS path.")
		e = look_for_files(config['garmin_gps_volume'] + "/Garmin/Activities/*.fit")	# Edge 500,530
		f = look_for_files(config['garmin_gps_volume'] + "/Garmin/ACTIVITY/*.FIT")	# Edge 130
		g = look_for_files(config['garmin_gps_volume'] + "/Garmin/Activity/*.fit")	# Edge 130+
		fit_files = e + f + g
		if len(fit_files) > 0:
			# We need to move these files off the drive or the 130 will simply rename them back to ".FIT",
			# causing them to be re-imported.
			archive_path = os.path.join(config['gps_files_folder'], 'Processed')
			if not os.path.isdir(archive_path):
				os.makedirs(archive_path)

			for fit_file in fit_files:
				base_name = fit_file.split('/')[-1]
				base_name_no_ext = ''.join(base_name.split('.')[0:-1])
				print(fit_file)
				path_to_gpx = os.path.join(config['gps_files_folder'], base_name_no_ext + '.gpx')
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
			print("Converted " + str(len(fit_files)) + " FIT files to GPX.")

	#
	# Phase 2: Import new CR files from camera card device (and convert to DNG)
	#

	card_files_list = []
	local_files_list = []
	# If there is a card path, make sure the archive folder exists on it, and look for CR files.
	if (not os.path.isdir(config['card_volume'])) and (not os.path.isdir(config['local_cr_folder'])):
		print("Cannot find card volume " + config['card_volume'] + " or local import folder.  Skipping import stage.")
	else:
		if os.path.isdir(config['card_volume']):
			print("Found card path.")
			# Make sure the archive folder on the card exists
			if not os.path.isdir(card_archive_folder):
				mkdir_out = subprocess.check_output("mkdir \"" + card_archive_folder + "\"", shell=True)
				if not os.path.isdir(card_archive_folder):
					print("Cannot create image archive path " + card_archive_folder + " .")
					exit()
				else:
					print("Created image archive path " + card_archive_folder + " .")

			# Look for CR files on the card
			card_files_list = look_for_files(config['card_volume'] + "/DCIM/*/*.CR2") + look_for_files(config['card_volume'] + "/DCIM/*/*.CR3")
			if len(card_files_list) > 0:
				print("Found " + str(len(card_files_list)) + " CR files.")
			else:
				print("No CR files found on card.")
		if os.path.isdir(config['local_cr_folder']):
			print("Found local import folder.")
			# Make sure the archive folder exists
			if not os.path.isdir(local_cr_archive_folder):
				mkdir_out = subprocess.check_output("mkdir \"" + local_cr_archive_folder + "\"", shell=True)
				if not os.path.isdir(local_cr_archive_folder):
					print("Cannot create image archive path " + local_cr_archive_folder + " .")
					exit()
				else:
					print("Created image archive path " + local_cr_archive_folder + " .")

			# Look for CR files in the folder
			local_files_list = look_for_files(config['local_cr_folder'] + "/*.CR2") + look_for_files(config['local_cr_folder'] + "/*.CR3")
			if len(local_files_list) > 0:
				print("Found " + str(len(local_files_list)) + " CR files.")
			else:
				print("No CR files found in local import folder.")

	# Save any target file EXIF data we read for later so we don't need to read it twice.
	target_file_exif_data = {}

	file_collections_to_process = [[card_files_list, True], [local_files_list, False]]
	for collection in file_collections_to_process:
		files_list = collection[0]
		from_card = collection[1]

		if len(files_list) > 0:

			all_exif_data = {}
			already_processed = []
			newly_processed = []

			for original in files_list:

				exif_bits = get_exif_bits_from_file(config['exiftool'], original)

				if prepend_datestamp_to_photo_files == 'True':
					target_file = exif_bits['form_date'] + "_" + exif_bits['file_name_no_ext'] + ".dng"
				else:
					target_file = exif_bits['file_name_no_ext'] + ".dng"

				exif_bits['target_file_name'] = target_file
				exif_bits['target_file_pathname'] = os.path.join(config['dng_folder'], target_file)
				exif_bits['gps_added'] = False

				# If the target file exists AND the datestamp in the EXIF matches exactly,
				# consider this file already processed.
				exif_bits['target_exif'] = {}
				if not os.path.exists(exif_bits['target_file_pathname']):
					exif_bits['target_exists'] = False
					exif_bits['already_converted'] = False
				else:
					texif_bits = get_exif_bits_from_file(config['exiftool'], exif_bits['target_file_pathname'])
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

				print(exif_bits['file_name_no_ext'] + ":   Date: " + pretty_datetime(exif_bits['date_and_time_as_datetime']) + has_gps_str + already_conv_str)

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
						"\"" + config['dng_folder'] + "\"",
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

					if from_card:
						archive_path = os.path.join(card_archive_folder, exif_bits['date_as_str'])
						if not os.path.isdir(archive_path):
							os.makedirs(archive_path)
					else:
						archive_path = os.path.join(local_cr_archive_folder, exif_bits['date_as_str'])
						if not os.path.isdir(archive_path):
							os.makedirs(archive_path)

					archive_pathname = os.path.join(archive_path, exif_bits['file_name'])
					print('moving "' + original + '" to "' + archive_pathname + '"')
					shutil.move(original, archive_pathname)

				all_exif_data[original] = exif_bits

			print("Already verified processed: " + str(len(already_processed)))
			print("Newly Processed: " + str(len(newly_processed)))
			to_move = already_processed + newly_processed
			print("Moved to archive folder: " + str(len(to_move)))

	#
	# Phase 2-b: Locate pre-existing DNG / HEIC files and read their EXIF tags as well
	#

	dng_list = look_for_files(config['dng_folder'] + "/*.dng")
	if len(dng_list) < 1:
			print("No DNG files found in target folder.")
	else:
		print("Found " + str(len(dng_list)) + " DNG files.")

		# Fetch EXIF data for any DNGs that we haven't already
		# (That would be all the DNGs that were in the target folder already
		#  and didn't have filenames matching CRs)
		additional_exif_fetches = 0
		for dng_file in dng_list:
			if dng_file not in target_file_exif_data:

				exif_bits = get_exif_bits_from_file(config['exiftool'], dng_file)
				if exif_bits['has_gps']:
					has_gps_str = "   Has GPS "
				else:
					has_gps_str = "           "
				print(exif_bits['file_name_no_ext'] + ":   Date: " + pretty_datetime(exif_bits['date_and_time_as_datetime']) + has_gps_str)

				target_file_exif_data[dng_file] = exif_bits
				additional_exif_fetches = additional_exif_fetches + 1
		if additional_exif_fetches > 0:
			print("Fetched EXIF data for an additional " + str(additional_exif_fetches) + " pre-existing DNG files.")

	heic_list = look_for_files(config['dng_folder'] + "/*.HEIC")
	if len(heic_list) > 0:
		print("Found " + str(len(heic_list)) + " HEIC files.")

		additional_exif_fetches = 0
		for heic_file in heic_list:
			exif_bits = get_exif_bits_from_file(config['exiftool'], heic_file)
			if exif_bits['has_gps']:
				has_gps_str = "   Has GPS "
			else:
				has_gps_str = "           "
			print(exif_bits['file_name_no_ext'] + ":   Date: " + pretty_datetime(exif_bits['date_and_time_as_datetime']) + has_gps_str)

			target_file_exif_data[heic_file] = exif_bits
			additional_exif_fetches = additional_exif_fetches + 1
		if additional_exif_fetches > 0:
			print("Fetched EXIF data for an additional " + str(additional_exif_fetches) + " pre-existing HEIC files.")

	#
	# Phase 3: Ensure that a reasonably unique identifier is embedded in all found photos
	#

	found_list = dng_list + heic_list
	if len(found_list) < 1:
		print("Skipping unique ID stage.")
	else:
		print("Starting unique ID stage.")
		# Filter out images with content in their SpecialInstructions EXIF tags.
		images_without_ids = []
		for image_file in found_list:
			if not target_file_exif_data[image_file]['special_instructions']:
				images_without_ids.append(image_file)
		if len(images_without_ids) < 1:
			print("All image files have unique ID tags.  Skipping unique ID stage.")
		else:
			print("Found " + str(len(images_without_ids)) + " image files without unique IDs.")

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
		print("Skipping comment embed stage.")
	else:
		print("Starting comment embed stage.")
		# Filter out DNGs with valid GPS data in their EXIF tags.
		images_without_comments = []
		for image_file in found_list:
			if not target_file_exif_data[image_file]['has_description']:
				images_without_comments.append(image_file)
		if len(images_without_comments) < 1:
			print("All DNG files have embedded comments.  Skipping comment embed stage.")
		else:
			print("Found " + str(len(images_without_comments)) + " DNG files without comments.")
			comments_to_consider = get_recent_short_comments(config)
			if len(comments_to_consider) < 1:
				print("No un-paired comments to consider.  Skipping comment embed stage.")
			else:
				print("Found " + str(len(comments_to_consider)) + " comments to consider.")

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
						print(exif_bits['file_name_no_ext'] + ":  " + c)
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

	gpx_list = look_for_files(config['gps_files_folder'] + "/*.gpx")
	if len(gpx_list) < 1:
		print("No GPX files found in gps log folder.  Skipping geotag stage.")
		exit()
	print("Found " + str(len(gpx_list)) + " GPX files.")

	# Parse the GPX files to find their earliest timepoint and latest timepoint.
	gpx_files_stats = {}
	valid_gps_files = []
	for gpx_file in gpx_list:
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

		print(gpx_file + ":\t  Start: " + pretty_datetime(earliest_start) + "   End: " + \
				pretty_datetime(latest_end) + diags)

	if len(valid_gps_files) < 1:
		print("No GPX files have valid date ranges.  Skipping geotag stage.")
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

	print("Sorting " + str(len(all_gpx_points)) + " GPX points.")

	sorted_gpx_points = sorted(all_gpx_points, key=lambda x: x['t'], reverse=False)

	#
	# Phase 6: Examine all DNG files without GPS tags, and tag them if possible.
	#

	if len(dng_list) < 1:
		print("Skipping geotag stage.")
	else:
		print("Starting geotag stage.")
		# Filter out DNGs with valid GPS data in their EXIF tags.
		dngs_without_gps = []
		if replace_gps:
			dngs_without_gps = dng_list
		else:
			for dng_file in dng_list:
				if not target_file_exif_data[dng_file]['has_gps']:
					dngs_without_gps.append(dng_file)
		if len(dngs_without_gps) < 1:
			print("All DNG files have GPS tags.  Skipping geotag stage.")
		else:
			if replace_gps:
				print("Seeking GPS data for " + str(len(dngs_without_gps)) + " DNG files.  May overwrite existing GPS data.")
			else:
				print("Found " + str(len(dngs_without_gps)) + " DNG files without GPS data.")

			for dng_file in dngs_without_gps:
				exif_bits = target_file_exif_data[dng_file]
				photo_dt = exif_bits['date_and_time_as_datetime'] + time_offset_for_photo_locations
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
				# each within the specified maximum gap size of its neighbors.
				if i > 1 and i < (len(sorted_gpx_points)-1):
					found_midpoint = True
				if not found_midpoint:
					print(exif_bits['file_name_no_ext'] + ": No points within range.")
				else:
					photo_time_delta = photo_dt - sorted_gpx_points[i-1]['t']

					gap = maximum_gps_time_difference_from_photo
					delta_during = sorted_gpx_points[i]['t'] - sorted_gpx_points[i-1]['t']
					delta_before = sorted_gpx_points[i-1]['t'] - sorted_gpx_points[i-2]['t']
					delta_after = sorted_gpx_points[i+1]['t'] - sorted_gpx_points[i]['t']
					if delta_during > gap or delta_before > gap or delta_after > gap:
						print(exif_bits['file_name_no_ext'] + ": Falls on a gap larger than 15 minutes.")
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
						
						el_calc += altitude_offset_for_photo_locations

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

						print(exif_bits['file_name_no_ext'] + ":  Lat " + str(abs(lat_calc)) + " " + lat_ref_str + "   Lon " + \
								str(abs(lon_calc)) + " " + long_ref_str + "   Alt " + str(abs(el_calc)) + "m " + el_ref)

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
		print("Cannot find chart output path " + chart_output_folder + " .")
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
	print("Found " + str(len(continuous_ranges)) + " continuous ranges.")

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

	print("Done.")


if __name__ == "__main__":
   main(sys.argv[1:])
