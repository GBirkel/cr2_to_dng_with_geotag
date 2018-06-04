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

gps_files_folder = "/Users/gbirkel/Documents/GPS/"	# For finding .gpx files to assign geotags from

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
		print "Cannot create image archive path " + cardpath + " ."
		exit()
	else:
		print "Created image archive path " + cardpath + " ."


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
		diags = "   (Bad range, won\'t use.)"
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

	filename = file_pathname.split('/')[-1]
	filename_no_ext = ''.join(filename.split('.')[0:-1])

	exif_d['full_date'] = df + " " + t
	exif_d['form_date'] = df + "-" + tf
	exif_d['has_gps'] = has_gps
	exif_d['filename'] = filename
	exif_d['filename_no_ext'] = filename_no_ext

	return exif_d


all_exif_data = {}
target_file_exif_data = {}

already_processed = []
newly_processed = []

for original in files_list:

	xf = get_exif_bits_from_file(original)

	target_file = xf['form_date'] + "_" + xf['filename_no_ext'] + ".dng"

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

	print xf['filename_no_ext'] + ":   Date: " + xf['full_date'] + "   Has GPS: " + str(xf['has_gps']) + "\tAlready Processed: " + str(xf['already_converted'])

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

	all_exif_data[original] = xf

print "Already verified processed: " + str(len(already_processed))
print "Processed: " + str(len(newly_processed))

to_move = already_processed + newly_processed

for original in to_move:
	xf = all_exif_data[original]
	mv_cmd = 'mv "' + original + '" "' + archivefolder + '\' + xf['filename'] + '"'
	print mv_cmd
	mv_out = subprocess.check_output(mv_cmd, shell=True) 

print "Moved to archive folder: " + str(len(to_move))

# TODO: Read EXIF for all DNG In target, fold into list, find those without gps, attempt tag
#		target_file_exif_data[xf['target_file_pathname']] = txf


print "Done."
