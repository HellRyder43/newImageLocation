import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:native_exif/native_exif.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Image Location',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(title: 'Image Location'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  File? _image;
  final picker = ImagePicker();

  CameraController? controller;

  Position? _currentPosition;
  String? _currentAddress;

  @override
  initState() {
    super.initState();
    WidgetsBinding.instance!.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    controller?.dispose();
    WidgetsBinding.instance!.removeObserver(this);
    super.dispose();
  }

  Future<bool> _handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Location services are disabled. Please enable the services')));
      return false;
    }
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are denied')));
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Location permissions are permanently denied, we cannot request permissions.')));
      return false;
    }
    return true;
  }

  Future<void> _getCurrentPosition() async {
    final hasPermission = await _handleLocationPermission();

    if (!hasPermission) return;
    await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
        .then((Position position) {
      setState(() => _currentPosition = position);
    }).catchError((e) {
      //debugPrint(e);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (controller == null || !controller!.value.isInitialized) {
      return;
    }
    if (state == AppLifecycleState.inactive) {
      controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (controller != null) {
        _initCamera();
      }
    }
  }

  void _initCamera() async {
    controller?.dispose();

    var cameras = await availableCameras();
    controller = CameraController(cameras[0], ResolutionPreset.high);
    await controller!.initialize();
    setState(() {});
  }

  Future onCameraCapture() async {
    if (controller == null || !controller!.value.isInitialized) {
      return;
    }

    if (!mounted) {
      return;
    }

    var path = await takePicture(controller!);
    _getCurrentPosition();
    if (path.isNotEmpty) {
      setState(() {
        _image = File(path);
      });
    }
  }

  Future<String> takePicture(CameraController controller) async {
    if (!controller.value.isInitialized) {
      return "";
    }

    if (controller.value.isTakingPicture) {
      // A capture is already pending, do nothing.
      return "";
    }

    try {
      final f = await controller.takePicture();
      return f.path;
    } on CameraException catch (e) {
      return "";
    }
  }

  Future getImage() async {
    var image = await picker.getImage(source: ImageSource.gallery);

    setState(() {
      if (image != null) {
        _image = File(image.path);
      }
    });
  }

  Future<String> getAddressFromLatLng() async {
    var photoAddress = "";
    await placemarkFromCoordinates(
            _currentPosition!.latitude, _currentPosition!.longitude)
        .then((List<Placemark> placemarks) {
      Placemark place = placemarks[0];
      // setState(() {
      //   _currentAddress =
      //   '${place.street}, ${place.subLocality}, ${place.subAdministrativeArea}, ${place.postalCode}';
      // });
      photoAddress =
          '${place.street}, ${place.locality}, ${place.subLocality}, ${place.administrativeArea}, ${place.subAdministrativeArea}, ${place.postalCode}';
    }).catchError((e) {
      debugPrint(e);
    });

    return photoAddress;
  }

  Future<String> getExifFromFile() async {
    if (_image == null) {
      return "";
    }

    //Sample to insert lat and long to image
    final exif = await Exif.fromPath(_image!.path); //get image exif data
    final attributes = await exif.getAttributes(); //get exif attributes
    attributes!['GPSLatitude'] =
        _currentPosition?.latitude ?? ""; //insert latitude
    attributes!['GPSLongitude'] =
        _currentPosition?.longitude ?? ""; //insert longitude
    await exif.writeAttributes(attributes); //write to image

    var bytes = await _image!.readAsBytes();
    var tags = await readExifFromBytes(bytes);
    var sb = StringBuffer();

    tags.forEach((k, v) {
      if (k == "GPS GPSLatitude") {
        sb.write("$k: $v \n");
      }
      if (k == "GPS GPSLatitudeRef") {
        sb.write("$k: $v \n");
      }
      if (k == "GPS GPSLongitude") {
        sb.write("$k: $v \n");
      }
      if (k == "GPS GPSLongitudeRef") {
        sb.write("$k: $v \n");
      }
    });

    //Return all exif data
    // tags.forEach((k, v) {
    //   sb.write("$k: $v \n");
    // });

    return sb.toString();
  }

  Future<Widget> getImageFromCamera(BuildContext context) async {
    Widget res;
    if (_image == null) {
      res = const Text('No image selected.');
    } else {
      var imageData = _image!.readAsBytesSync();

      var imageDataCompressed =
          await FlutterImageCompress.compressWithList(imageData);
      res = Image.memory(Uint8List.fromList(imageDataCompressed));
    }
    return res;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image Location'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.camera),
            onPressed: onCameraCapture,
          )
        ],
      ),
      body: ListView(children: <Widget>[
        Column(
          children: <Widget>[
            const Text(
              'Camera Preview',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            SizedBox(
              height: 200.0,
              child: controller?.value.isInitialized ?? false
                  ? CameraPreview(controller!)
                  : Container(),
            ),
            const SizedBox(
              height: 20,
            ),
            FutureBuilder(
                future: getImageFromCamera(context),
                builder:
                    (BuildContext context, AsyncSnapshot<Widget> snapshot) {
                  if (snapshot.hasData) {
                    if (snapshot.data != null) {
                      return SizedBox(
                        height: 200.0,
                        child: snapshot.data,
                      );
                    } else {
                      return const CircularProgressIndicator();
                    }
                  }
                  return Container();
                }),
            const SizedBox(
              height: 20,
            ),
            const Text(
              'Exif Data from Image',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            FutureBuilder(
              future: getExifFromFile(),
              builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
                if (snapshot.hasData) {
                  if (snapshot.data != null) {
                    return Text(snapshot.data ?? "");
                  } else {
                    return const CircularProgressIndicator();
                  }
                }
                return Container();
              },
            ),
            const Text(
              'Get Address from Lat/Long',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            FutureBuilder(
              future: getAddressFromLatLng(),
              builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
                if (snapshot.hasData) {
                  if (snapshot.data != null) {
                    return Text(snapshot.data ?? "");
                  } else {
                    return const CircularProgressIndicator();
                  }
                }
                return Container();
              },
            ),
          ],
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        onPressed: getImage,
        tooltip: 'Pick Image',
        child: const Icon(Icons.photo_library),
      ),
    );
  }
}
