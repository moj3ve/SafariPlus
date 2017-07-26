//  downloadManager.xm
//  Downloads multiple files through NSURLSession

// (c) 2017 opa334

#import "downloadManager.h"

@implementation downloadManager

+ (instancetype)sharedInstance
{
    static downloadManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[downloadManager alloc] init];
        sharedInstance.downloads = [NSMutableArray new];
        //Create message center to communicate with SpringBoard through RocketBootstrap
        CPDistributedMessagingCenter* tmpCenter = [%c(CPDistributedMessagingCenter) centerNamed:@"com.opa334.SafariPlus.MessagingCenter"];
        rocketbootstrap_distributedmessagingcenter_apply(tmpCenter);
        sharedInstance.SPMessagingCenter = tmpCenter;
    });
    return sharedInstance;
}

- (NSMutableArray*)getDownloadsForPath:(NSURL*)path
{
  //Return pending downloads of given path
  NSMutableArray* downloadsForPath = [NSMutableArray new];
  for(Download* download in self.downloads)
  {
    if([download.filePath.path isEqualToString:path.path])
    {
      [downloadsForPath addObject:download];
    }
  }
  return downloadsForPath;
}

- (NSString*)generateIdentifier
{
  //Generate random identifier for download
  NSString* bundleID = @"com.opa334.SafariPlus.download";
  NSString* UUID = [[NSUUID UUID] UUIDString];
  return [NSString stringWithFormat:@"%@-%@", bundleID, UUID];
}

- (void)prepareDownloadFromRequest:(NSURLRequest*)request withSize:(int64_t)size fileName:(NSString*)fileName
{
  [self prepareDownloadFromRequest:request withSize:size fileName:fileName customPath:NO];
}

- (void)prepareDownloadFromRequest:(NSURLRequest*)request withSize:(int64_t)size fileName:(NSString*)fileName customPath:(BOOL)customPath
{
  NSURL* path;
  if(!customPath)
  {
    if(preferenceManager.customDefaultPathEnabled)
    {
      path = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/User%@", preferenceManager.customDefaultPath]];
      BOOL isDir;
      BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:[path path] isDirectory:&isDir];
      if(!isDir || !exists)
      {
        UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:[localizationManager localizedSPStringForKey:@"ERROR"] message:[localizationManager localizedSPStringForKey:@"CUSTOM_DEFAULT_PATH_ERROR_MESSAGE"] preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];

        [errorAlert addAction:okAction];

        [self.rootControllerDelegate presentViewController:errorAlert];
        return;
      }
    }
    else
    {
      path = [NSURL fileURLWithPath:@"/User/Downloads/"];
    }
  }
  else
  {
    directoryPickerNavigationController* directoryPicker = [[directoryPickerNavigationController alloc] initWithRequest:request size:size path:path fileName:fileName];
    [self.rootControllerDelegate presentViewController:directoryPicker];
    return;
  }

  path = path.URLByResolvingSymlinksInPath;

  path = [NSURL fileURLWithPath:[[path path] stringByReplacingOccurrencesOfString:@"/var" withString:@"/private/var"]];

  //Check if file already exists
  if([[NSFileManager defaultManager] fileExistsAtPath:[[path URLByAppendingPathComponent:fileName] path]])
  {
    [self presentFileExistsAlert:request size:size fileName:fileName path:path];
  }

  else
  {
    [self startDownloadFromRequest:request size:size fileName:fileName path:path shouldReplace:NO];
  }
}

- (void)presentFileExistsAlert:(NSURLRequest*)request size:(int64_t)size fileName:(NSString*)fileName path:(NSURL*)path
{
  UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:[localizationManager localizedSPStringForKey:@"ERROR"] message:[localizationManager localizedSPStringForKey:@"FILE_EXISTS_MESSAGE"] preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *replaceAction = [UIAlertAction actionWithTitle:[localizationManager localizedSPStringForKey:@"REPLACE_FILE"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) //Start download and replace file
        {
          [self startDownloadFromRequest:request size:size fileName:fileName path:path shouldReplace:YES];
        }];

  UIAlertAction *changePathAction = [UIAlertAction actionWithTitle:[localizationManager localizedSPStringForKey:@"CHANGE_PATH"]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) //Present directory picker
        {
          directoryPickerNavigationController* directoryPicker = [[directoryPickerNavigationController alloc] initWithRequest:request size:size path:path fileName:fileName];
          [self.rootControllerDelegate presentViewController:directoryPicker];
        }];

  UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:[localizationManager localizedSPStringForKey:@"CANCEL"]
        style:UIAlertActionStyleCancel handler:nil]; //Do nothing

  //Add actions to alert
  [errorAlert addAction:replaceAction];
  [errorAlert addAction:changePathAction];
  [errorAlert addAction:cancelAction];

  [self.rootControllerDelegate presentViewController:errorAlert];
}

- (void)handleDirectoryPickerResponse:(NSURLRequest*)request size:(int64_t)size fileName:(NSString*)fileName path:(NSURL*)path
{
  //Check if file already exists
  if([[NSFileManager defaultManager] fileExistsAtPath:[[path URLByAppendingPathComponent:fileName] path]])
  {
    [self presentFileExistsAlert:request size:size fileName:fileName path:path];
  }
  else
  {
    [self startDownloadFromRequest:request size:size fileName:fileName path:path shouldReplace:NO];
  }
}

- (void)startDownloadFromRequest:(NSURLRequest*)request size:(int64_t)size fileName:(NSString*)fileName path:(NSURL*)path shouldReplace:(BOOL)shouldReplace
{
  Download* download = [[Download alloc] init];
  download.downloadManagerDelegate = self;
  download.fileSize = size;
  download.fileName = fileName;
  download.filePath = path;
  download.replaceFile = shouldReplace;
  download.identifier = [self generateIdentifier];
  download.updateCount = 40;
  [download startDownloadFromRequest:request];
  [self.downloads addObject:download];

  __block NSString* fileNameLocal = download.fileName;

  //If app is active: Send status bar notification
  if([[UIApplication sharedApplication] applicationState] == 0 && !preferenceManager.disableBarNotificationsEnabled)
  {
    [self.rootControllerDelegate dismissNotificationWithCompletion:^
    {
      [self.rootControllerDelegate dispatchNotificationWithText:
        [NSString stringWithFormat:@"%@: %@", [localizationManager localizedSPStringForKey:@"DOWNLOAD_STARTED"], fileNameLocal]];
    }];
  }
  //If app is inactive: Send push notification (using rocketbootstrap and libbulletin) (Probably never used here, but better safe than sorry)
  else if([[UIApplication sharedApplication] applicationState] != 0 && !preferenceManager.disablePushNotificationsEnabled)
  {
    NSDictionary* userInfo = @{ @"title"     : @"SAFARI",
                                @"message" : [NSString stringWithFormat:@"%@: %@", [localizationManager localizedSPStringForKey:@"DOWNLOAD_STARTED"], fileNameLocal],
                                @"bundleID" : @"com.apple.mobilesafari"
                              };

    [self.SPMessagingCenter sendMessageName:@"pushNotification" userInfo:userInfo];
  }
}

- (void)downloadFinished:(Download*)download withLocation:(NSURL*)location
{
  [self removeDownloadWithIdentifier:download.identifier];

  NSURL* path = [download.filePath URLByAppendingPathComponent:download.fileName];

  if(download.replaceFile)
  {
    [[NSFileManager defaultManager] removeItemAtPath:[path path] error:nil];
  }

  [[NSFileManager defaultManager] moveItemAtURL:location toURL:path error:nil];

  __block NSString* fileNameLocal = download.fileName;

  //If app is active: Send status bar notification
  if([[UIApplication sharedApplication] applicationState] == 0 && !preferenceManager.disableBarNotificationsEnabled)
  {
    [self.rootControllerDelegate dismissNotificationWithCompletion:^
    {
      [self.rootControllerDelegate dispatchNotificationWithText:
        [NSString stringWithFormat:@"%@: %@", [localizationManager localizedSPStringForKey:@"DOWNLOAD_SUCCESS"], fileNameLocal]];
    }];
  }
  //If app is inactive: Send push notification (using rocketbootstrap and libbulletin)
  else if([[UIApplication sharedApplication] applicationState] != 0 && !preferenceManager.disablePushNotificationsEnabled)
  {
    NSDictionary* userInfo = @{ @"title"     : @"SAFARI",
                                @"message" : [NSString stringWithFormat:@"%@: %@", [localizationManager localizedSPStringForKey:@"DOWNLOAD_SUCCESS"], fileNameLocal],
                                @"bundleID" : @"com.apple.mobilesafari"
                              };

    [self.SPMessagingCenter sendMessageName:@"pushNotification" userInfo:userInfo];
  }

  [self.downloadTableDelegate reloadDataAndDataSources];

  download = nil;
}

- (void)downloadCancelled:(Download*)download
{
  [self removeDownloadWithIdentifier:download.identifier];
  download = nil;
  [self.downloadTableDelegate reloadDataAndDataSources];
}

- (void)removeDownloadWithIdentifier:(NSString*)identifier
{
  for(Download* download in self.downloads)
  {
    if([download.identifier isEqualToString:identifier])
    {
      [self.downloads removeObject:download];
      return;
    }
  }
}

@end

@implementation Download

- (void)startDownloadFromRequest:(NSURLRequest*)request
{
  NSURLSessionConfiguration* config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:self.identifier];
  config.sessionSendsLaunchEvents = YES;
  config.allowsCellularAccess = !preferenceManager.onlyDownloadOnWifiEnabled;

  self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

  self.downloadTask = [self.session downloadTaskWithRequest:request];
  [self.downloadTask resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
  [session invalidateAndCancel];
  [self.downloadManagerDelegate downloadFinished:self withLocation:location];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten
totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
  @try //Avoid crash that happens really really rarely (wasn't even able to reproduce it and I tried it around 50 times)
  {
    self.updateCount++;
    self.totalBytesWritten = totalBytesWritten;
    int64_t bytesPerSecond = (totalBytesWritten - self.startBytes) / ([NSDate timeIntervalSinceReferenceDate] - self.startTime);

    if(self.cellDelegate)
    {
      [self.cellDelegate updateProgress:totalBytesWritten totalBytes:totalBytesExpectedToWrite bytesPerSecond:bytesPerSecond animated:YES];
    }

    if(self.updateCount >= 40) //refreshing speed every 40 calls
    {
      self.startTime = [NSDate timeIntervalSinceReferenceDate];
      self.startBytes = totalBytesWritten;
      self.updateCount = 0;
    }
  }
  @catch(NSException* exception)
  {
    NSLog(@"EXCEPTION: %@", exception);
  }
}

- (void)cancelDownload
{
  [self.downloadTask cancel];
  [self.downloadManagerDelegate downloadCancelled:self];
}

- (void)pauseDownload
{
  self.paused = YES;
  [self.downloadTask suspend];
}

- (void)resumeDownload
{
  self.paused = NO;
  self.updateCount = 40;
  [self.downloadTask resume];
}


@end