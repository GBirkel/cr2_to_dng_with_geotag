#!/usr/local/bin/python

# This script does the following:
# 1. Look for a media card (by looking for a specific path)
# 2. Locate CR2 picture files on the media card
# 3. Read the capture date, and the flag indicating GPS data present, from each image
# 4. Make a filename prefix based on the capture date
# 5. If a DNG image with the same filename and the same capture date exists in a target folder, ignore the image
# 6. Look for GPX data files from a GPS in a given folder
# 7. If no GPS data is present in the image, attempt to geotag it using the GPX files
# 8. Convert the image to Adobe DNG format and copy it to a given target folder
# 9. Move the original image to a given 'processed' folder (should be on the media card itself) 

import os, sys, re
import subprocess
import gpxpy
from datetime import datetime

# TODO: Convery all to DNG in a first step (skipping if needed)
# then move/delete
# then do the gps/gpx check

# Before using:

# brew install exiftool
# pip install gpxpy
# Download and install Adobe DNG Converter
# (https://supportdownloads.adobe.com/detail.jsp?ftpID=6319)

cardpath = "/Volumes/EOS_DIGITAL"
outfolder = "/Users/gbirkel/Pictures/DNG_RAW_In"

gps_files_folder = "/Users/gbirkel/Documents/GPS/"	# For finding .gpx files to assign geotags from

exiftool = "/usr/local/bin/exiftool"
dngconverter = "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"

# References:
# http://wwwimages.adobe.com/www.adobe.com/content/dam/acom/en/products/photoshop/pdfs/dng_commandline.pdf
# https://www.awaresystems.be/imaging/tiff/tifftags/privateifd/exif.html
# https://sno.phy.queensu.ca/~phil/exiftool/geotag.html
# https://www.sno.phy.queensu.ca/~phil/exiftool/faq.html
# https://github.com/guinslym/pyexifinfo

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


# Look for CR2 files on the card
ls_out = subprocess.check_output("ls " + cardpath + "/DCIM/*/*.CR2", shell=True) 
files_list = ls_out.split("\n")
files_list = [f for f in files_list if len(f) > 4]

print "Found " + str(len(files_list)) + " CR2 files."
if len(files_list) < 1:
	exit()


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


# look for GPX files
ls_out = subprocess.check_output("ls " + gps_files_folder + "*.gpx", shell=True) 
gpx_files_list = ls_out.split("\n")
gpx_files_list = [f for f in gpx_files_list if len(f) > 4]

print "Found " + str(len(gpx_files_list)) + " GPX files."

gpx_files_stats = {}
for gpx_file in gpx_files_list:
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
		diags = '   (Bad range, won\'t use.)'
	else:
		stats = {}
		stats['start'] = earliest_start
		stats['end'] = latest_end
		gpx_files_stats[gpx_file] = stats

	print gpx_file + ":\t  Start: " + datetime_to_str(earliest_start) + "   End: " + datetime_to_str(latest_end) + diags



# Support function to invoke exiftool and pull out and parse two major pieces of data:
# The creation date from the camera, and the active status of the GPS device in the camera while shooting.
def get_exif_bits_from_file(file_pathname):
	gps_stat_out = subprocess.check_output(exiftool + " -a -s -GPSStatus -SubSecCreateDate " + file_pathname, shell=True)
	exif_d = {}

	full_date = gps_stat_out.split('SubSecCreateDate')[1].strip(' \t\n\r:')
	d, t = full_date.split(" ")
	df = re.sub(':', '-', d)
	tf = re.sub('[:\.]', '', t)

	has_gps = "Void" in gps_stat_out

	filename_no_ext = ''.join(file_pathname.split('/')[-1].split('.')[0:-1])

	exif_d['full_date'] = df + " " + t
	exif_d['form_date'] = df + "-" + tf
	exif_d['has_gps'] = has_gps
	exif_d['filename_no_ext'] = filename_no_ext

	return exif_d


all_exif_data = {}

already_processed = []
processed_with_gps = []
processed_added_gps = []

for original in files_list:

	xf = get_exif_bits_from_file(original)

	target_file = xf['form_date'] + "_" + xf['filename_no_ext'] + ".dng"

	xf['target_file_name'] = target_file
	xf['target_file_pathname'] = outfolder + "/" + target_file
	xf['gps_added'] = False

	# If the target file exists AND the datestamp matches exactly when we extract the EXIF data,
	# consider this file already processed.
	xf['target_exif'] = {}
	if not os.path.exists(xf['target_file_pathname']):
		xf['target_exists'] = False
		xf['already_converted'] = False
	else:
		xf['target_exists'] = True
		xf['target_exif'] = get_exif_bits_from_file(xf['target_file_pathname'])
		xf['already_converted'] = xf['target_exif']['form_date'] == xf['form_date']

	print xf['filename_no_ext'] + ":   Date: " + xf['full_date'] + "   Has GPS: " + str(xf['has_gps']) + "\tAlready Processed: " + str(xf['already_converted'])

	if xf['already_converted']:
		already_processed.append(original)
	else:

		if not xf['has_gps']:
			source_file = original
			processed_added_gps.append(original)
		else:
			source_file = original
			processed_with_gps.append(original)

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
			"\"" + source_file + "\""	# Input file is last
		]

		# -j : Launch the app hidden
		# -n : Open a new instance of the application even if one is already running
		# -W : Block and wait for the application to exit
		# -a : Path to application to open
		# --args : Everything beyond here should be passed to the application
		conv_command = "open -j -n -W -a \"" + dngconverter + "\" --args " + ' '.join(conv_args)

		#dng_conv_output = subprocess.check_output(conv_command, shell=True)

	all_exif_data[original] = xf

print "Already verified processed: " + str(len(already_processed))
print "Processed with GPS already present: " + str(len(processed_with_gps))
print "Processed and attempted added GPS: " + str(len(processed_added_gps))

print "Done."
