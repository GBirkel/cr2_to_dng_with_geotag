#!/usr/local/bin/python

import os, sys, re
import subprocess
import gpxpy
from datetime import datetime

# TODO: Convery all to DNG in a first step (skipping if needed)
# then move/delete
# then do the gps/gpx check

#
# Customize before using:
#

cardpath = "/Volumes/EOS_DIGITAL"
outfolder = "/Users/gbirkel/Pictures/DNG_RAW_In"
archivefolder = cardpath + "/archived"

gps_files_folder = "/Users/gbirkel/Documents/GPS"	# For finding .gpx files to assign geotags from

exiftool = "/usr/local/bin/exiftool"
dngconverter = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"


if not os.path.exists(dngconverter):
	print "Install the Adobe DNG converter, please."
	exit()
if not os.path.exists(exiftool):
	print "Install exiftool with \"brew install exiftool\", please."
	exit()
if not os.path.isdir(outfolder):
	print "Cannot find file out path " + outfolder + " ."
	exit()
if not os.path.isdir(cardpath):
	print "Cannot find card path " + cardpath + " ."
	exit()

print "Found card path."

if not os.path.isdir(archivefolder):
	mkdir_out = subprocess.check_output("mkdir \"" + archivefolder + "\"", shell=True) 
	if not os.path.isdir(archivefolder):
		print "Cannot create image archive path " + archivefolder + " ."
		exit()
	else:
		print "Created image archive path " + archivefolder + " ."


# Support function to look for files on a given path
def look_for_files(p):
	try:
		ls_out = subprocess.check_output("ls " + p, shell=True)
		files_list = ls_out.split("\n")
		files_list = [f for f in files_list if len(f) > 4]
	except subprocess.CalledProcessError as e:
		files_list = []
	return files_list


# Support function to pretty-print dates that datetime can't handle
def datetime_to_str(t):

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
	time_str = '%02d:%02d%s' % (hour, t.minute, half_day)	

	return date_str + ', ' + time_str


# Support function to invoke exiftool and pull out and parse two major pieces of data:
# The creation date from the camera, and the active status of the GPS device in the camera while shooting.
def get_exif_bits_from_file(file_pathname):
	gps_stat_out = subprocess.check_output(
		exiftool + " -a -s -GPSStatus -SubSecCreateDate " + file_pathname, shell=True)
	exif_d = {}

	full_date = gps_stat_out.split('SubSecCreateDate')[1].strip(' \t\n\r:')
	d, t = full_date.split(" ")
	df = re.sub(':', '-', d)
	tf = re.sub('[:\.]', '', t)

	has_gps = "Active" in gps_stat_out

	file_name = file_pathname.split('/')[-1]
	file_name_no_ext = ''.join(file_name.split('.')[0:-1])

	exif_d['full_date'] = df + " " + t
	exif_d['form_date'] = df + "-" + tf
	exif_d['has_gps'] = has_gps
	exif_d['file_name'] = file_name
	exif_d['file_name_no_ext'] = file_name_no_ext

	return exif_d


# Look for CR2 files on the card
files_list = look_for_files(cardpath + "/DCIM/*/*.CR2")

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
		xf['target_file_pathname'] = outfolder + "/" + target_file
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

		print xf['file_name_no_ext'] + ":   Date: " + xf['full_date'] + has_gps_str + already_conv_str

		if xf['already_converted']:
			already_processed.append(original)
		else:
			newly_processed.append(original)
			conv_args = [
				'-c',		# Lossless compression
				'-p1',		# Medium preview
				'-fl',		# Fast-load data
				'-cr7.1',	# Camera Raw v7.1 and up compatible (works with Aperture)
				'-dng1.4',	# DNG file format 1.4 and up compatible (works with Aperture)
				'-d',		# Output directory
				"\"" + outfolder + "\"",
				'-o',		# Output file
				"\"" + xf['target_file_name'] + "\"",
				"\"" + original + "\""	# Input file is last
			]

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

		all_exif_data[original] = xf

	print "Already verified processed: " + str(len(already_processed))
	print "Newly Processed: " + str(len(newly_processed))

	to_move = already_processed + newly_processed

	for original in to_move:
		xf = all_exif_data[original]
		orig_file_name = xf['file_name']
		archive_pathname = archivefolder + "/" + orig_file_name
		mv_cmd = 'mv "' + original + '" "' + archive_pathname + '"'
		print mv_cmd
		mv_out = subprocess.check_output(mv_cmd, shell=True) 

	print "Moved to archive folder: " + str(len(to_move))


# Look for DNG files in the target folder

dng_list = look_for_files(outfolder + "/*.dng")
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
		print xf['file_name_no_ext'] + ":   Date: " + xf['full_date'] + has_gps_str

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
		stats['start'] = earliest_start
		stats['end'] = latest_end
		gpx_files_stats[gpx_file] = stats
		valid_gps_files.append(gpx_file)

	print gpx_file + ":\t  Start: " + datetime_to_str(earliest_start) + "   End: " + \
            datetime_to_str(latest_end) + diags

if len(valid_gps_files) < 1:
   	print "No GPX files have valid date ranges.  Skipping geotag stage."
	exit()

for dng_file in dngs_without_gps:
	xf = target_file_exif_data[dng_file]	
	gpx_files_in_range = []
	for gpx_file in valid_gps_files:
		stats = gpx_files_stats[gpx_file]
    	



# TODO:  find compatible ranges, attempt tag


print "Done."
