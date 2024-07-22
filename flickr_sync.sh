#!/Applications/Xcode.app/Contents/Developer/usr/bin/python3

import os, sys, re
import getopt
import codecs
import shutil
import subprocess
import flickrapi
from common_utils import *
from datetime import datetime, tzinfo, timedelta
from xml.etree import ElementTree

#
# Customize config.xml before using!
#


def check_all_paths(config):
	if not os.path.exists(config['exiftool']):
		print("Install exiftool with \"brew install exiftool\", please.")
		return False
	if not os.path.isdir(config['flickr_sync_folder']):
		print("Cannot find flickr_sync_folder at: " + config['flickr_sync_folder'] + " .")
		return False
	return True


def main(argv):
	force_replace = False
	try:
		opts, args = getopt.getopt(argv,"hf",["forcereplace"])
	except getopt.GetoptError:
		print('flickr_sync.sh -h for invocation help')
		sys.exit(2)
	for opt, arg in opts:
		if opt == '-h':
			print('-f or --forcereplace to force the replacing of existing images even if the metadata is identical')
			sys.exit()
		if opt in ("-f", "--forcereplace"):
			force_replace = True

	config = read_config()
	if config is None:
		print('Error reading your config.xml file!')
		sys.exit(2)

	if check_all_paths(config) == False:
		sys.exit()

	# Save any target file EXIF data we read for later so we don't need to read it twice.
	sync_file_exif_data = {}

	#
	# Phase 1: Locate any files in the sync folder and get their EXIF info
	#

	jpg_list = look_for_files(config['flickr_sync_folder'] + "/*.jpg")
	if len(jpg_list) < 1:
		print("No JPG files found in sync folder.")
	else:
		print("Found %s JPG files." % str(len(jpg_list)))

		for jpg_file in jpg_list:

			exif_bits = get_exif_bits_from_file(config['exiftool'], jpg_file)
			if exif_bits['has_gps']:
				has_gps_str = 'Has GPS'
			else:
				has_gps_str = ''
			if exif_bits['image_dimensions']:
				dimensions_str = exif_bits['image_dimensions']
			else:
				dimensions_str = ''

			if exif_bits['has_creation_date']:
				taken = pretty_datetime(exif_bits['date_and_time_as_datetime'])
			else:
				taken = 'UNKNOWN'

			print("%s:\tTaken: %s\tSize: %s\t%s" % (exif_bits['file_name_no_ext'], taken, dimensions_str, has_gps_str))

			sync_file_exif_data[jpg_file] = exif_bits

	#
	# Phase 2: Connect to Flickr and confirm the Album we're working with exists
	#

	print("\nConnecting to Flickr.")

	# initialize
	flickr = flickrapi.FlickrAPI(config['flickr_api_key'], config['flickr_api_secret'], format='parsed-json')
	flickr.authenticate_via_browser(perms='write')

	# Look up account info by email address
	rsp = flickr.people.findByEmail(api_key=config['flickr_api_key'], find_email=config['flickr_account_email'])
	print("Response: %s" % repr(rsp))
	flickr_user_id = rsp['user']['id']

	# Get the current list of albums (sets) for the user on Flickr
	response = flickr.photosets.getList(
				user_id=flickr_user_id,
				per_page='300')
	photosets = response['photosets']

	matching_set = None
	for one_set in photosets['photoset']:
		if one_set['title']['_content'] == config['flickr_album_to_add_to']:
			matching_set = one_set
			break

	if matching_set is None:
		print("Could not find an album on Flickr with name \"%s\"" % config['flickr_album_to_add_to'])
		sys.exit(2)

	working_album_id = matching_set['id']
	print("Working album is \"%s\", with ID %s\n" % (config['flickr_album_to_add_to'], working_album_id))

	#
	# Phase 3: Check for matching photos on Flickr
	#

	# Save any target file EXIF data we read for later so we don't need to read it twice.
	flickr_current_data = {}

	files_on_flickr = []
	files_not_on_flickr = []
	files_status_unknown = []

	for jpg_file in jpg_list:
		e = sync_file_exif_data[jpg_file]

		if not e['has_creation_date']:
			print("%s:\tPhoto does not have a creation date, cannot search Flickr." % e['file_name_no_ext'])
			files_status_unknown.append(jpg_file)
			continue

		# Note that Flickr IGNORES the time zone indicator in the EXIF of any photo
		# it processes internally.  This may have seemed like a sane decision 15 years ago
		# but it's horrifying today.
		# To match what Flickr expects, we're amputating the time zone from our own date:
		search_time = e['date_and_time_as_datetime'].strftime('%Y-%m-%d %H:%M:%S')

		# Search for a matching photo
		response = flickr.photos.search(
					user_id=flickr_user_id,
					per_page='10',
					min_taken_date=search_time,
					max_taken_date=search_time,
					extras='o_dims,date_taken')
		photos = response['photos']

		if photos['total'] == 0:
			print("%s:\tNo photos matching date on Flickr." % e['file_name_no_ext'])
			files_not_on_flickr.append(jpg_file)
		elif photos['total'] > 1:
			print("%s:\t%s photos matching date on Flickr, cannot process." % (e['file_name_no_ext'], photos['total']))
			files_status_unknown.append(jpg_file)
		elif 'image_dimensions' not in e:
			print("%s:\tFound photo on Flickr by date but cannot compare dimensions." % e['file_name_no_ext'])
			files_status_unknown.append(jpg_file)
		else:
			file_x, file_y = e['image_dimensions'].split(u'x')
			flickr_photo_data = photos['photo'][0]
			flickr_x = int(flickr_photo_data['o_width'])
			flickr_y = int(flickr_photo_data['o_height'])
			if (int(file_x) != flickr_x) or (int(file_y) != flickr_y):
				print("%s:\tFound photo on Flickr by date but dimensions are different: %sx%s vs %sx%s" %
					(e['file_name_no_ext'], file_x, file_y, flickr_x, flickr_y))
				files_status_unknown.append(jpg_file)
			else:
				print("%s:\tFound photo on Flickr by date and dimensions.\t*" % e['file_name_no_ext'])
				flickr_current_data[jpg_file] = flickr_photo_data
				files_on_flickr.append(jpg_file)

	print("%s JPG files were not found on Flickr and will be considered new" % str(len(files_not_on_flickr)))
	print("%s JPG files were found on Flickr" % str(len(files_on_flickr)))
	print("%s JPG files have undetermined status and will be ignored." % str(len(files_status_unknown)))

	#
	# Phase 4: Upload any that are considered new
	#

	print("\nStarting upload sequence:")
	for jpg_file in files_not_on_flickr:
		e = sync_file_exif_data[jpg_file]

		description = ""
		if e['has_description']:
			description = e['Description']
		response = flickr.upload(
			api_key = config['flickr_api_key'],
			filename = jpg_file,
			title = e['file_name_no_ext'],
			description = description,
			is_public = "1",
			format = 'etree'
		)
		response_type = response.get('stat')
		if response_type != 'ok':
			print("%s:\tError uploading. Reponse type: %s" % (e['file_name_no_ext'], e['response_type']))
			continue

		photo_id = response.find('photoid').text
		response = flickr.photosets.addPhoto(
			api_key = config['flickr_api_key'],
			photoset_id =working_album_id,
			photo_id = photo_id
		)

		print("%s:\tUploaded and added to album." % e['file_name_no_ext'])

	print("Done.")


if __name__ == "__main__":
   main(sys.argv[1:])
