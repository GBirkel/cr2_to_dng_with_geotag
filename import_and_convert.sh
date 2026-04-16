#!/Applications/Xcode.app/Contents/Developer/usr/bin/python3

import os, sys, re
import getopt
import codecs
import shutil
import subprocess
import json
import hashlib
from datetime import datetime, tzinfo, timedelta
import math
import gpxpy

from common_utils import *
from gps_utils import get_date_ranges_in_gpx_file, get_basic_points_from_gpx_file, BasicGpsPoint, GpsPointWithEcef, GpsLeg

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
			print('-r or --replacegps to overwrite existing GPS data in photos when new data is available')
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
	photo_card_archive_folder = config['card_volume'] + "/archived"

	time_offset_for_photo_locations = timedelta(seconds=int(config['time_offset_for_photo_locations']))
	altitude_offset_for_photo_locations = float(config['altitude_offset_for_photo_locations'])


	if check_all_paths(config) == False:
		sys.exit()

	#
	# Phase 1: Import new FIT files from GPS device (and convert to GPX)
	#

	folders_to_search_for_fit_files = [config['gps_files_reprocess_folder'] + "/*.fit"]
	if os.path.exists(config['garmin_gps_volume']):
		print("Found GPS path.")
		folders_to_search_for_fit_files += [
			config['garmin_gps_volume'] + "/Garmin/Activities/*.fit",	# Edge 500,530
			config['garmin_gps_volume'] + "/Garmin/ACTIVITY/*.FIT",	# Edge 130
			config['garmin_gps_volume'] + "/Garmin/Activity/*.fit",	# Edge 130+
		]
	fit_files = look_for_files(folders_to_search_for_fit_files)
	if len(fit_files) > 0:
		# We need to move these files off the drive or the 130 will simply rename them back to ".FIT",
		# causing them to be re-imported.
		archive_path = os.path.join(config['gps_files_folder'], 'Processed')
		if not os.path.isdir(archive_path):
			os.makedirs(archive_path)

		resulting_gps_files = []
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
			fit_convert_cmd = config['gpsbabel'] + " " + ' '.join(gpsbabel_args)
			fit_conv_out = subprocess.check_output(fit_convert_cmd, shell=True)
			# If we use move, MacOS will attempt to copy file permissions.
			# On Garmin devices, FIT files are shown with permissions of 777.
			# Since the executable permission is set, MacOS will try to apply that, which will fail due to system protection measures.
			# Trying to change the permissions on the source file in place will have no result.
			# So we use copyfile instead, which does not attempt to set equivalent permissions, then remove the source file afterwards.
			shutil.copyfile(fit_file, os.path.join(archive_path, base_name))
			os.remove(fit_file)
			resulting_gps_files.append(path_to_gpx)
		print("Converted " + str(len(fit_files)) + " FIT files to GPX.")

		# Now that we're created GPX files, we invoke GPSBabel again to split the GPX data on gaps in distance.
		# The application currently doesn't support splitting on distance OR time in one go.
		# https://github.com/gpsbabel/gpsbabel/issues/379
		# Note: This apparently does not work because you can't split an already split GPX file in GPSBabel without packing it again first.

		#if not do_not_split_gpx:
		if not 1:
			print("Splitting GPX again on distances larger than 1000 meters.")
			for gps_file in resulting_gps_files:
				base_name = gps_file.split('/')[-1]
				base_name_no_ext = ''.join(base_name.split('.')[0:-1])
				path_to_split_gpx = os.path.join(config['gps_files_folder'], base_name_no_ext + '-split.gpx')
				gpsbabel_args = [
					'-i gpx',				# Input format
					'-f',					# Input file
					gps_file,
					'-x track,sdistance=1000m,title="LOG # %c"', # Split if gap is larger than 1000 meters
					'-o gpx,garminextensions=1',				# Output format GPX with Garmin extensions
					'-F',					# Output file
					'"' + path_to_split_gpx + '"'
				]
				gpx_split_cmd = config['gpsbabel'] + " " + ' '.join(gpsbabel_args)
				gpx_split_out = subprocess.check_output(gpx_split_cmd, shell=True)
				os.remove(gps_file)

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
			if not os.path.isdir(photo_card_archive_folder):
				mkdir_out = subprocess.check_output("mkdir \"" + photo_card_archive_folder + "\"", shell=True)
				if not os.path.isdir(photo_card_archive_folder):
					print("Cannot create image archive path " + photo_card_archive_folder + " .")
					exit()
				else:
					print("Created image archive path " + photo_card_archive_folder + " .")

			# Look for CR files on the card
			card_files_list = look_for_files([
				config['card_volume'] + "/DCIM/*/*.CR2",
				config['card_volume'] + "/DCIM/*/*.CR3"
			])
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
			local_files_list = look_for_files([
				config['local_cr_folder'] + "/*.CR2",
				config['local_cr_folder'] + "/*.CR3"
			])
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

				if config['prepend_datestamp_to_photo_files'] == 'True':
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
					conv_command = "open -j -n -W -a \"" + config['dngconverter'] + "\" --args " + ' '.join(conv_args)

					dng_conv_output = subprocess.check_output(conv_command, shell=True)

					# Now there's a target file with the same EXIF data as the original,
					# So we save the EXIF data we pulled from the original under a reference to the target.
					target_file_exif_data[exif_bits['target_file_pathname']] = exif_bits

					if from_card:
						archive_path = os.path.join(photo_card_archive_folder, exif_bits['date_as_str'])
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
				exif_id_embed_cmd = config['exiftool'] + " " + ' '.join(exif_id_embed_args)
				exif_id_embed_out = subprocess.check_output(exif_id_embed_cmd, shell=True)

	#
	# Phase 4: Fetch a list of recent short comments from the Mile42 blog
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
						exif_embed_cmd = config['exiftool'] + " " + ' '.join(exif_embed_args)
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
	valid_gps_files = []
	for gpx_file in gpx_list:
		[start_date, end_date] = get_date_ranges_in_gpx_file(gpx_file)
		print(gpx_file + ":\t  Start: " + pretty_datetime(start_date) + "   End: " + \
				pretty_datetime(end_date))
		if start_date.year < 1980 or start_date.year > 2030 or end_date.year < 1980 or end_date.year > 2030:
			print("   (Bad range, won\'t use.)")
		valid_gps_files.append(gpx_file)

	if len(valid_gps_files) < 1:
		print("No GPX files have valid date ranges.  Skipping geotag stage.")
		exit()

	# The plan here is to read all the data points from all the valid GPX files at once,
	# then use the nearest points before and after a photo timestamp to find the relevant point for that photo.
	# Of course, if we've somehow recorded two tracks for the same time period in very different locations,
	# this will make a mess.  But this is a single-user script and that situation is beyond the design spec.

	all_gpx_points:list[BasicGpsPoint] = []
	for gpx_file in valid_gps_files:
		basic_points = get_basic_points_from_gpx_file(gpx_file)
		all_gpx_points += basic_points

	print("Sorting " + str(len(all_gpx_points)) + " GPX points.")

	sorted_gpx_points = sorted(all_gpx_points, key=lambda x: x.time, reverse=False)

	# Average the position and speed values of points within a rolling six-second window.

	smoothed_gpx_points: list[BasicGpsPoint] = []
	# A pool of all previously seen points that are within 6.01 seconds
	# of the current point (including the current point).
	point_pool: list[BasicGpsPoint] = []
	smoothing_range = timedelta(seconds=6)
	i = 0
	# We will be handling all these attributes the same way
	attributes_to_smooth = ['lat', 'lon', 'elevation', 'speed']
	while i < len(sorted_gpx_points):
		current_point = sorted_gpx_points[i]
		i += 1

		cur_time = current_point.time

		point_pool.append(current_point)
		# Drop any point older than 6.01 seconds.
		# This way, large gaps in the recorded data halt the smoothing effect.
		filtered_pool = []
		for p in point_pool:
			if abs(cur_time - p.time) < smoothing_range:
				filtered_pool.append(p)
		point_pool = filtered_pool
		# Start with a template point that has all the
		# attributes we wish to smooth zeroed out.
		
		smoothed_point = BasicGpsPoint(
			time = cur_time,
			lat = 0.0,
			lon = 0.0,
			elevation = 0.0,
			speed = 0.0,
			original_point = current_point.original_point
		)
		
		total_multiplier = 0
		# Add each point's attributes to the template point, multiplying them
		# first by a 'force multiplier' based on the distance in time from the current point.
		# The more distant the time (up to 6 seconds) the lower the force multiplier.
		for p in point_pool:
			this_multiplier = (timedelta(seconds=7) - (cur_time - p.time)).total_seconds()
			total_multiplier += this_multiplier
			for measurement_type in attributes_to_smooth:
				setattr(smoothed_point, measurement_type, getattr(smoothed_point, measurement_type) + getattr(p, measurement_type) * this_multiplier)
		# Divide the template attributes by the total force multiplier applied,
		# to get values that make sense.  Basically, the new current point is like the
		# old current point except it has ~6 seconds of "drag" applied to it.
		for measurement_type in attributes_to_smooth:
			setattr(smoothed_point, measurement_type, getattr(smoothed_point, measurement_type) / total_multiplier)
		smoothed_gpx_points.append(smoothed_point)

	# Calculate ECEF coordinates for all points, so they can be compared in 3D space.

	smoothed_points_with_ecef: list[GpsPointWithEcef] = []
	for pt in smoothed_gpx_points:
		smoothed_points_with_ecef.append(GpsPointWithEcef(basic_point=pt))

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
				while i < len(smoothed_points_with_ecef) and not found_highpoint:
					if smoothed_points_with_ecef[i].time > photo_dt:
						found_highpoint = True
					else:
						i += 1
				found_midpoint = False

				# To ensure a decent GPS read, we want a
				# location that has at least two points on either side,
				# each within the specified maximum gap size of its neighbors.
				if i > 1 and i < (len(smoothed_points_with_ecef)-1):
					found_midpoint = True
				if not found_midpoint:
					print(exif_bits['file_name_no_ext'] + ": No points within range.")
				else:
					p_prev = smoothed_points_with_ecef[i-1]
					p_this = smoothed_points_with_ecef[i]
					p_next = smoothed_points_with_ecef[i+1]
					photo_time_delta = photo_dt - p_prev.time
					gap = timedelta(seconds=int(config['maximum_gps_time_difference_from_photo']))
					delta_during = p_this.time - p_prev.time
					delta_before = p_prev.time - smoothed_points_with_ecef[i-2].time
					delta_after = p_next.time - p_this.time
					if delta_during > gap or delta_before > gap or delta_after > gap:
						print(exif_bits['file_name_no_ext'] + ": Falls on a gap larger than 15 minutes.")
					else:

						# In GPX files, latitude and longitude are supplied as decimal degrees
						# and are allowed a negative range, e.g. -180 to 180 for longitude.

						# Calculate the delta for the latitude, longitude, and elevation.
						lat_start = p_prev.lat
						lon_start = p_prev.lon
						el_start = p_prev.elevation
						lat_delta = p_this.lat - lat_start
						lon_delta = p_this.lon - lon_start
						el_delta = p_this.elevation - el_start

						# Find a mid-point for the photo, interpolating based on the time.
						lat_calc = p_prev.lat
						lon_calc = p_prev.lon
						el_calc = p_prev.elevation
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
						exif_gps_embed_cmd = config['exiftool'] + " " + ' '.join(exif_gps_embed_args)
						exif_gps_embed_out = subprocess.check_output(exif_gps_embed_cmd, shell=True)

	#
	# Phase 7: Use current stock of GPX data to generate a set of GPS journeys, composed of one or more legs,
	#          broken across gaps in recording larger than six hours,
	#          or gaps in distance larger than 1000 meters.

	# The "larger than six hour break" rule is needed because the beginning and ending of each day
	# will change based on the time zone, so breaking across days is cumbersome, especially
	# if the rider rides past midnight.

	legs: list[GpsLeg] = []
	smallest_allowable_distance_gap = 1000.0  # meters
	if do_not_split_gpx:
		smallest_allowable_time_gap = timedelta(hours=60000)
	else:
		smallest_allowable_time_gap = timedelta(hours=6)

	this_range_start = 0
	prev_point = smoothed_points_with_ecef[0]
	leg_point_accumulator = []
	supplemental = False
	next_is_supplemental = False
	i = 1

	while i < len(smoothed_points_with_ecef):
		pt = smoothed_points_with_ecef[i]

		cur_time = pt.time
		time_delta = cur_time - prev_point.time

		distance = pt.distance_from(prev_point)

		start_of_new_leg = False

		# If the gap between this point and the last is larger than smallest_allowable_time_gap,
		# or if the distance between this point and the last is larger than smallest_allowable_distance_gap,
		# declare a new range
		if time_delta > smallest_allowable_time_gap:
			print("Found a time gap of {} hours at between time {} and {}".format(time_delta.total_seconds() / 3600, pretty_datetime(prev_point.time), pretty_datetime(cur_time)))
			start_of_new_leg = True
			next_is_supplemental = False
		elif distance > smallest_allowable_distance_gap:
			print("Found a distance gap of {:.2f} meters between time {} and {}".format(distance, pretty_datetime(prev_point.time), pretty_datetime(cur_time)))
			start_of_new_leg = True
			# If the current point has a gap in space but not time, we treat the leg we're about to declare as supplemental to the last one.
			next_is_supplemental = True

		prev_point = pt

		if start_of_new_leg:
			# Runs less than 60 samples are ignored
			if len(leg_point_accumulator) > 60:
				new_leg = GpsLeg(
					points = leg_point_accumulator,
					supplemental = supplemental
				)
				legs.append(new_leg)
			supplemental = next_is_supplemental
			leg_point_accumulator = []
		leg_point_accumulator.append(pt)
		i += 1
	# Deal with what remains on the accumulator
	if len(leg_point_accumulator) > 60:
		new_leg = GpsLeg(
			points = leg_point_accumulator,
			supplemental = supplemental
		)
		legs.append(new_leg)
	print("Found " + str(len(legs)) + " continuous ranges.")

	# Now let's create a "reduced" set of points for each range.
	# This is the data we'll use for embedding in the site.

	reduced_legs = []
	total_original_point_count = 0
	total_reduced_point_count = 0

	for leg in legs:
		reduced_leg = leg.make_reduced_version(minimum_distance = 5.0)
		reduced_legs.append(reduced_leg)
		
		total_original_point_count += len(leg.points)
		total_reduced_point_count += len(reduced_leg.points)

	difference = total_original_point_count - total_reduced_point_count
	if difference > 0:
		percentage_reduced = (difference / total_original_point_count) * 100
		print("Skipped " + str(difference) + " points that were too close, for a {:.2f}%".format(percentage_reduced) + " reduction.")

	# Collect legs that are identified as supplemental into the same ride.

	rides = []
	current_ride = []
	ride_identifier = None
	i = 0
	while i < len(legs):
		leg = legs[i]
		reduced_leg = reduced_legs[i]
		print("Ride " + str(i) + " supplemental: " + str(reduced_leg.supplemental))
		if not reduced_leg.supplemental:
			if len(current_ride) > 0:
				rides.append({
					'identifier': ride_identifier,
					'legs': current_ride})
				current_ride = []
		if len(current_ride) == 0:
			ride_identifier = leg.identifier
		current_ride.append({
			'full': leg,
			'reduced': reduced_leg})
		i += 1
	if len(current_ride) > 0:
		rides.append({
			'identifier': ride_identifier,
			'legs': current_ride})
		current_ride = []

	# Write the ranges out to an HTML gallery and a JSON file.

	chart_out_path = os.path.join(config['chart_output_folder'], 'route_gallery.html')
	json_out_path = os.path.join(config['chart_output_folder'], 'route_gallery.json')

	template_file_h = open("route_template.html", "r")
	template_html = template_file_h.read()
	template_file_h.close()

	cofh = open(chart_out_path, "w")
	cofh.write(template_html)
	gallery_json = []

	for r in rides:
		ride_identifier = r['identifier']

		legs = r['legs']

		date_start = legs[0]['full'].start_time
		date_end = legs[-1]['full'].end_time
		gps_start_point_latitude = legs[0]['full'].points[0].lat
		gps_start_point_longitude = legs[0]['full'].points[0].lon

		if len(legs) > 1:
			reduced_gps_data = {
				'legs': [leg['reduced'].as_compact_json() for leg in legs],
				'distance_meters': sum(leg['reduced'].distance_meters for leg in legs),
				'duration_seconds': sum(leg['reduced'].duration_seconds for leg in legs)
			}
		else:
			reduced_gps_data = legs[0]['reduced'].as_compact_json()

		cofh.write("<div class='ptws-ride-log' rideid=" + '"' + ride_identifier + '"' + ">\n<div class='data'>")
		# We write this JSON structure out twice:
		# Once in the HTML file to display the routes in a gallery,
		range_json_str = json.dumps(reduced_gps_data)
		cofh.write(range_json_str)
		cofh.write("</div>\n</div>\n")
		# and once in a JSON file that we use as reference material for uploading the routes to the web
		gallery_json.append([ride_identifier, range_json_str])

	cofh.write("\n</body>\n</html>")
	cofh.close()

	gallery_json_obj = {}
	gallery_json_obj['a'] = gallery_json
	with open(json_out_path, 'w') as json_out_handle:
		json.dump(gallery_json_obj, json_out_handle)

	print("Done.")


if __name__ == "__main__":
   main(sys.argv[1:])
