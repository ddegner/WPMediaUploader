Hello,

Thank you for the feedback. Below is everything needed to test all features of the app.

The app requires an SSH connection to a WordPress server. I have a live test server set up exclusively for App Store review.

STEP 1 — CREATE A PROFILE IN THE APP
Open the app, create a new profile, and enter these settings:

Profile Name: Test Profile
Host: 150.136.174.3
Port: 22
Username: tester
Authentication: Password
Password: YjDUEquAe46lveCSf9
WP Root Path: /var/www/html
Staging Root: ~/wp-media-import

Click "Test Connection" - you should see confirmations for SSH, WP-CLI, and WordPress detection. Then click Save.

STEP 2 — UPLOAD THE TEST IMAGE
A file called test.jpg has been included with these instructions. In the app, select test.jpg using the file picker or drag and drop it onto the app window.

STEP 3 — RUN THE UPLOAD
Click the Upload button. The app will transfer test.jpg to the server via rsync over SSH, then import it into the WordPress Media Library using WP-CLI. This typically completes in under 30 seconds and will display a success message with the WordPress attachment ID.

STEP 4 — VERIFY IN WORDPRESS
Open the WordPress Media Library to confirm the image was imported:
URL: http://150.136.174.3/wp-admin/upload.php
Username: admin
Password: bSdGAF2CQkn8lBTqje

test.jpg should appear at the top of the Media Library.

STEP 5 — NEW IN 1.1 (OPTIONAL): LOCAL AVIF GENERATION
Edit the profile and enable "Generate AVIFs locally", then upload test.jpg again. After the WordPress import completes, the app encodes AVIF versions of the image and its thumbnail sizes on-device (no server-side encoding) and uploads them into the site's wp-content/uploads directory next to the JPEG files. The job log shows a "Sideloading AVIFs" stage, and the finished job reports how many AVIF files were created. This feature is designed to complement the AVIF Local Support WordPress plugin, but it does not require the plugin to run.

Please don't hesitate to reply if you run into any issues.

Thank you for your time reviewing my app.

Best regards,
David Degner
