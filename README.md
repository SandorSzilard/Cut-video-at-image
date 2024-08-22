# Cut-video-at-image
A Powershell script using ffmpeg to find an image in a video and cut the video at the image (similar to the application "cut at black" but it can be used with any image from the movie => ex. an intro screen in a serial maraton compilation, slicing the compilation in smaller chunks)

The implementation uses different scripts and programming languages to obtain the wanted result.

This project was made by test, combining different powershel scripts and own javascript code for formatting (becasue I don't really understand Regex/powershell, but I understand JS).

The main part is composed from 3 Scripts:

1. Detect image:
   -By default, it gets the 10th frame as the "logo" and compares that to the rest of the video => It can be manually added at the beginnig of the file (you will have to *COMMENT* the code at line 15,16 and *UNCOMMENT* line 19.
   -It uses ffmpeg  to search and mark the occurences of each frame that contains the image
   -each occurence is then saved in a csv and a JSON (to be formatted later by JS)
   -the script then opens the HTML and it saves the computed output
   -after the output is saved in the main folder, the user has to press OK, so the script can process forward (if you have multiple videos, it will process the next one; if not, then it will call the splicer script for sepparating the videos)

3. Index HTML (and json.js, main.js)
   -It calls for the data and the main.js functionality
   -main.js searches for the consecutive frames that contains the image and marks the duration at which the video will be cut; it outputs a txt file (Don't change the name) and it makes it possible to download
   -you have to download the file (without changing the name) in the main folder

4. Cut Video
   -It is called automatically at the end of the "detect image" script
   -it splices the videos into chunks and puts them in the *Outputs* folder

#You will have to download ffmpeg.exe and put it in the main folder (sorry...it's too big for Git): https://ffmpeg.org/download.html


# How to use it:
1. Put your videos in the "Videos" folder
2. Run the "1.Detect_Image" script (by default, it will detect the 10th frame as the "image") => ignore the errors, the script is running, but it takes some time depending on the length of the videos
3. After detecting, the script will open a webpage => save the document in the main folder (where the scripts and index.html is located); After that you can close the page;
4. Press OK on the popup screen from the script (!!! _WARNING_ !!! Don't press OK, untill the file from the HTML is saved inside the root folder !!!! )
5. *Depending if you have multiple videos* Step 3-4 will have to be repeated (as many times as many videos you have)
6. When all the videos were processed and the cutpoints were marked, a popup will mark that you can proceed to the video slicing process; Press OK
7. Slicing is done automatically, the output is exported to the "Outputs" folder => if the script is not working, you can run it manually ("3. Cut_Video")


## Tested on Windows Powershell (windows 10)! I don't guarantee it will work on Linux/Mac/etc.)
