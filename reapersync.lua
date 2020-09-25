os = reaper.GetOS(); 
if os ~= "Win32" and os ~= "Win64" then
    s = "/"
    prefix="xterm -e ";
    if os=="OSX32" or os=="OSX64" then
      prefix="/bin/bash -c ";
    end
  else
    s = "\\"
    prefix="\"c:\\Program Files\\Git\\git-bash.exe\" -c ";
  end 

--reaper.ShowConsoleMsg(prefix);
  
function refreshTracks()
  basepath = reaper.GetProjectPath(0,"");
  --files = scandir(basepath)
  files=getParts(basepath..s.."parts");
  for k,file in pairs(files) do
    if (file~=".git") then 
      decodeFilesInPart(file);
      refreshPart(file);
    end
  end
end

function refreshAudio(user)
  name,server,username,root=getPrefs();
  song=getSongName();
  script="rsync -ai -r --chmod=g+rwx -p --progress "..username.."@"..server..":"..root.."/"..song.."/ogg .";
  run(script);
end

function pushAudio(user)
  name,server,username,root=getPrefs();
  song=getSongName();
  script="rsync -ai -r --chmod=g+rwx -p --progress ./ogg/"..name.." "..username.."@"..server..":"..root.."/"..song.."/ogg";
  run(script);
end

function setupLocalRepo()
  result = isOnServer();
  if (result) then
    clone();
  else
    createRemoteRepo()
    clone();
  end
end

function syncRepo()
  script = "cd parts; git add . --all; git commit -m 'no message'; git pull --no-edit origin master; git commit -m 'Still no message'; git push --set-upstream origin master";
  run(script);
end

function maybeSetupRepo()
   basepath = reaper.GetProjectPath(0,"");
   if exists(basepath,"parts") then
   else
      setupLocalRepo();
   end
end

function clone()
  basepath = reaper.GetProjectPath(0,"");
  song = getSongName();
  name,server,username,root=getPrefs();
  run("git clone ssh://"..username.."@"..server..":"..root.."/"..song.."/parts ");
end

function isOnServer()
  name,server,username,root=getPrefs();
  local cmd='ssh '..username.."@"..server..' \"cd '..root..';ls \''..getSongName()..'\'\"';
  --println(cmd);
  filelist=io.popen(cmd);
  for filename in filelist:lines() do
    if (filename=="parts") then
      return true;
    end
  end
  return false;
end

function getSongName()
 song = reaper.GetProjectName(0,"");
 song=song:gsub(".rpp",""):gsub(".RPP","");
 return song;
end

function createRemoteRepo()
   basepath = reaper.GetProjectPath(0,"");
   name,server,username,root=getPrefs();
   song=getSongName();
   run('ssh '..username.."@"..server..' \'cd '..root..';git init --shared --bare \''..song..'/parts\';mkdir -p \''..song..'/ogg\';chmod g+ws \''..song..'/ogg"\'');
end

function getParts(basepath)
  index=0;
  files={};
  while true do  --iterate and store files in project folder
      local file=reaper.EnumerateSubdirectories(basepath, index)
      if file then
          table.insert(files, file)
          index=index+1
      else
          break
      end
  end
  return files;
end

function getTrackFiles(basepath,person)
  index=0;
  files={};
  while true do  --iterate and store files in project folder
      local file=reaper.EnumerateFiles(basepath..s.."parts"..s..person, index)
      if file then
          files[file]=file;
          index=index+1
      else
          break
      end
  end
  return files;
end

function exists(basepath,name)
  index=0;
  files={};
  while true do  --iterate and store files in project folder
      local file=reaper.EnumerateSubdirectories(basepath, index)
      if file then
          if (file==name) then
            return true;
          end
          index=index+1;
      else
          return false
      end
  end
end


function reload()
  projectName = reaper.GetProjectPath(0,"");
  name =  reaper.GetProjectName(0,"");
  reaper.Main_openProject(projectName..s..name);
end

function run(cmd)
  basepath = reaper.GetProjectPath(0,"");
  runSilentlyInPath(basepath,cmd);
end

function runInPath(path, cmd)
    if (reaper.GetOS()== "Win32" or reaper.GetOS()=="Win64") then
        path="/"..path:gsub(":",""):gsub("\\","/")
    end
    local cmd = prefix.."\"set -x;cd '"..path.."' ; "..cmd.." ; echo Press Enter...;  read stuff\""
    println(cmd);
    return reaper.ExecProcess(cmd,0);
end

function runWithOutput(path, cmd)
    if (reaper.GetOS()== "Win32" or reaper.GetOS()=="Win64") then
        path="/"..path:gsub(":",""):gsub("\\","/")
    end
    cmd = prefix.."\"cd '"..path.."' ; "..cmd.." ; echo Press Enter...;  read stuff\"";
    println(cmd);
    return reaper.ExecProcess(cmd,0);
end

function fixWindowsPath(path)
  return "/"..path:gsub(":",""):gsub("\\","/")
end

function runSilentlyInPath(path, cmd)
    if (reaper.GetOS()== "Win32" or reaper.GetOS()=="Win64") then
        path="/"..path:gsub(":",""):gsub("\\","/")
    end
    cmd=prefix.."\"cd '"..path.."' ; "..cmd.." ; \"";
    println(cmd);
    return reaper.ExecProcess(cmd,0);
end

function trackpull()
  reaper.Main_SaveProject(0);
  projectName = reaper.GetProjectPath(0,"");
  result = runInPath(projectName,"trackpull");
  if (result) then
    reaper.ShowConsoleMsg("Pulled current track\n");
    reload()
  end
end

function push()
  name,server,username=getPrefs();
  writePart(name);
end

function print(str)
  reaper.ShowConsoleMsg(str);
end

function println(str)
  reaper.ShowConsoleMsg(str.."\n");
end

function indentHome(index)
  if (index>0) then 
    track=reaper.GetTrack(0,index-1);
    val=reaper.GetTrackDepth(track);
    reaper.SetMediaTrackInfo_Value(track,"I_FOLDERDEPTH",-1*val)
  end
end

function maybeCreateTrack(person)
  tracks,min = getTracksInPart(person);
  if (min==-1) then
      index=reaper.GetNumTracks();
      reaper.InsertTrackAtIndex(index,false);
      track = reaper.GetTrack(0,index);
      reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, 1)
      indentHome(index);
    return
  end
end

function checkDuplicates(person)
  basepath = reaper.GetProjectPath(0,"");
  files=getParts(basepath..s.."parts");
  myTracks=getTracksInPart(person);
  for k,file in pairs(files) do
    if (file~=".git" and file~=person) then
      tracks = getTrackFiles(basepath,file);
      for k,track in pairs(tracks) do
        track=track:gsub(".trk","")
        if (myTracks[track]~=nil) then
          index=getIndex(track)+1
          print("Stolen track found\n\nThe sync could not be performed as one of your tracks belongs to someone else. In order to modify someone else's track, please make a copy of the track and modify the copy. In order to fix this problem, please duplicate the track and move the original out of your folder.");
          assert(nil,"\nTrack "..index.." Ownership Problem - See Console for details");
        end
      end
    end
  end
end

function checkOrphans(person)
  basepath = reaper.GetProjectPath(0,"");
  files=getParts(basepath..s.."parts");
  for k,file in pairs(files) do
    if (file~=".git" and file~=person) then
      myTracks=getTracksInPart(file);
      tracks = getTrackFiles(basepath,file);
      for k,track in pairs(myTracks) do
        track=k..".trk",""
        if (tracks[track]==nil) then
          index=getIndex(k)+1
          print("Orphan track found\n\nThe sync could not be performed as track "..index.." is placed in a folder that does not belong to its owner. If you created this track and would like to keep it, please move it to your folder. Otherwise delete it and it will not be sent to the server.");
          assert(nil,"\nTrack "..index.." Ownership Problem - See Console for details");
        end
      end
    end
  end
end

function magiclines(s)
        if s:sub(-1)~="\n" then s=s.."\n" end
        return s:gmatch("(.-)\n")
end

function writePart(person)
  reaper.Main_SaveProject(0);
  projectPath = reaper.GetProjectPath(0,"");
 -- reaper.RecursiveCreateDirectory(projectPath..s.."parts",0);
  name=person;
  tracks,min,max = getTracksInPart(person);
  if (min==-1) then
    return
  end
  
  run("rm -rf ".."parts/"..person);
  reaper.RecursiveCreateDirectory(projectPath..s.."parts"..s..person,0) 
  prevguid="-1"
  for index=min,max do
    rtrack =reaper.GetTrack(0,index);
    retval,result=reaper.GetTrackStateChunk(rtrack,"",false);
--    println(projectPath);
--    println(result);
--    println("->");
    output="";
    for str in magiclines(result) do
      str=str:gsub("FILE \".*"..s,"FILE \"");
      output=output.."\n"..str;
    end
    result=output;
--    println("Done");
    file = io.open(projectPath..s.."parts"..s..person..s..(reaper.GetTrackGUID(rtrack))..".trk","w");
    io.output(file);
    parent = reaper.GetParentTrack(rtrack);
    retval,name=reaper.GetTrackName(rtrack);
    if (parent~=nil) then
    retval,pname=reaper.GetTrackName(parent);
    else
      pname="None";
    end
    --print(name .."'s -> parent is "..pname.."\n");
    --print(parent)
    if (parent~=nil) then
      io.write(reaper.GetTrackGUID(parent).."\n");
      --println(reaper.GetTrackGUID(rtrack).."'s  previous is"..prevguid);
      io.write(prevguid.."\n");
    else
      io.write("-1\n");
      io.write(prevguid.."\n");
    end
   -- io.write((reaper.GetTrackGUID(reaper.GetParentTrack(track))));
    io.write(result);
    io.close(file);
    prevguid=(reaper.GetTrackGUID(rtrack));
  end
  
end

function refreshPart(person)
  --println("Refreshing "..person);
 -- index = deletePart(person)
  importPart(person);
end

function getFilesInTrack(track, files)
  numItems=reaper.CountTrackMediaItems(track);
  for item=0,numItems-1 do
    mediaItem=reaper.GetTrackMediaItem(track,item);
    numTakes=reaper.CountTakes(mediaItem);
    for takeNum=0,numTakes-1 do
       take=reaper.GetMediaItemTake(mediaItem,takeNum);
       if (take~=nil) then
        source=reaper.GetMediaItemTake_Source(take);
        val=reaper.GetMediaSourceFileName(source,"");
        --smaller=val:gsub(".*"..s,""):gsub(".wav","");
        smaller="/"..val:gsub(".wav",""):gsub(":",""):gsub("\\","/");
        files[smaller]=smaller;
       end
    end
  end
end

function printArray(arr)
  print("\n");
  for k,v in pairs(arr) do
    print(k.." : "..v.."\n");
  end
  print("--\n")
end

function encodeFilesInPart(person)
  basepath = reaper.GetProjectPath(0,"");
  firstfiles=getFilesInPart(person);
  existing=getFilesInFolder(basepath..s.."ogg"..s..person,"ogg");
  files=getNewFiles(firstfiles,existing);
  cmd="";
  for k,v in pairs(files) do
    if os=="OSX32" or os=="OSX64" then
      cmd=cmd.."'"..reaper.GetResourcePath().."/Scripts/reach/macos/oggenc' -Q '"..v.."'.wav -o 'ogg/"..person..s..v:gsub(".*/","")..".ogg';";
     else
     cmd=cmd.."oggenc '"..v.."'.wav -o 'ogg/"..person..s..v:gsub(".*/","")..".ogg';";
     end
  end
  cmd=cmd.." echo hello";
  --print(cmd);
  --print(cmd);
  if (cmd~="") then 
      runSilentlyInPath(basepath,cmd);
  end
end

function runInMacTerminal(cmd)
  println("/usr/bin/osascript -e \"tell app \\\"Terminal\\\" to do script \\\"echo hello;read\\\"\"");
  reaper.ExecProcess("/usr/bin/osascript -e \"tell app \\\"Terminal\\\" to do script \\\"echo hello;read\\\"\"",0);
end

function decodeFilesInPart(person)
--  print("thing");
  basepath = reaper.GetProjectPath(0,"");
  firstfiles=getFilesInFolder(basepath..s.."ogg"..s..person,"ogg");
  existing=getFilesInFolder(basepath,"wav");
  files=getNewFiles(firstfiles,existing);
--  printArray(firstfiles);printArray(existing);printArray(files);
  cmd="";
  for k,v in pairs(files) do
      if os=="OSX32" or os=="OSX64" then
        cmd=cmd.."'"..reaper.GetResourcePath().."/Scripts/reach/macos/oggdec' -Q '"..v.."'.ogg -o '../../"..v..".wav';";
      elseif os=="Other" then
        cmd=cmd.."oggdec '"..v.."'.ogg -o '../../"..v..".wav';";
      else
        cmd=cmd.."oggdec '"..v.."'.ogg -w '../../"..v..".wav';";
      end
  end
  cmd=cmd.." echo hello";
--  cmd="/usr/local/bin/oggdec -Q test.ogg";
-- println(cmd);
  if (cmd~="") then 
--        runInMacTerminal("none");
      runSilentlyInPath(basepath..s.."ogg"..s..person,cmd);
  end
  
end

function getFilesInFolder(basepath,extension)
  index=0;
  files={};
  while true do  --iterate and store files in project folder
      local file=reaper.EnumerateFiles(basepath, index)
      if file then
          if (string.match(file,extension.."$")) then
            folderfile=file:gsub("."..extension,"");
            files[folderfile]=folderfile;
          end
          index=index+1
      else
          break
      end
  end
  return files;
end

function getFilesInPart(person)
  files={};
  for k,track in pairs(getTracksInPart(person)) do
     getFilesInTrack(track, files);
  end
  return files;
end

function getNewFiles(total, old)
  output={};
  for k,v in pairs(total) do
    --print(k):
    local check=k:gsub(".*/","");
    if old[check]==nil then
      output[k]=k;
    end
  end
  return output;
end

function getTracksInPart(person)
  found=false;
  min=-1;
  tracks={};
  max=reaper.GetNumTracks()-1
  for trackNum=0,reaper.GetNumTracks()-1 do
      track = reaper.GetTrack(0,trackNum);
      retval,title=reaper.GetTrackName(track,"","")
   
      if (found==false) then
        if (title==person) then
          found=true;
          parent=track;
          min=trackNum;
          max=trackNum;
        end
      else
        if (reaper.GetTrackDepth(track)<=reaper.GetTrackDepth(parent)) then
            break;
        else
          max=trackNum
        end
      end
  end
  if (min~=-1) then
    index=1;
    for toDelete = min, max do
      track = reaper.GetTrack(0,toDelete);
      tracks[reaper.GetTrackGUID(track)]=track; --breaking change
      index=index+1;
--      getAllFiles(track);
    end
  end
  return tracks,min,max;
end

function deletePart(person)
  
  tracks,pos=getTracksInPart(person);
  for k,track in pairs(tracks) do
     reaper.DeleteTrack(track);
  end
  if (pos==-1) then
    return reaper.GetNumTracks();
  else
  return pos;
  end
end

function readPart(person)
  projectPath = reaper.GetProjectPath(0,"");
  tracks = {};
  parents = {};
  prevs = {};
  
  files = getTrackFiles(projectPath,person);
  for k,file in pairs(files) do
    --print(file);
   -- print(file);
    parentguid="-1";
    prevguid="-1";
    lines="";
  --  print(projectPath..s.."parts"..s..person..s..file);
    pos = 0;
    for line in io.lines(projectPath..s.."parts"..s..person..s..file) do
      if (pos==0) then parentguid=line;pos=pos+1
        elseif (pos==1) then prevguid=line;pos=pos+1
        else lines= lines.."\n"..line
      end
    end    

    trackNum  = index; 
    --print(lines);
    --reaper.InsertTrackAtIndex(trackNum,false);
    --track = reaper.GetTrack(0,trackNum);
    if (trim(lines)~="") then
      tracks[file:gsub(".trk","")]=lines;
      if (parents[parentguid]==nil) then
        parents[parentguid]={}
        end
      if (prevs[prevguid]==nil) then
         prevs[prevguid]={}
         end
      
      parents[parentguid][file:gsub(".trk","")]=file:gsub(".trk","");
      prevs[prevguid][file:gsub(".trk","")]=file:gsub(".trk","");
    --reaper.SetTrackStateChunk(track,lines,false);
    lines="";
    end
  end
  
  return tracks, parents, prevs;
  --printArray(tracks);
  
end

function setup()
  retval, vals,other = reaper.GetUserInputs( "Setup", 4,"Your name,Server,Username,Path", "" )
  if (trim(vals)=="") then
    --reaper_
    reaper.ShowConsoleMsg("Values Unchanged"); 
    return
  end
  file = io.open (getPrefFile() , "w");
  io.output(file)
  io.write(vals);
  io.close(file);
end

function getPrefs()
   name = getPrefFile();
   file = io.open (name , "r");
   
   io.input(file)
   raw=io.read();
   if (raw==nil) then
    setup();
    return getPrefs();
   else 
   name,rest=raw:split(",");
   server,rest=rest:split(",");
   username,root=rest:split(",");
   io.close(file);
   return name,server,username,root;
   end
end

function string:split(sep)
  return self:match("([^" .. sep .. "]+)[" .. sep .. "]+(.+)")
end

function trim(s)
   return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function string.starts(String,Start)
   return string.sub(String,1,string.len(Start))==Start
end

function getPrefFile()
  kb = reaper.GetResourcePath()
  return kb..s.."Scripts"..s.."syncprefs.ini";
end

function selfUpdate()
  kb = reaper.GetResourcePath()
  path = kb..s.."Scripts"..s.."reach";
  runInPath(path,"git pull origin master");
end

function trackclone()
  retval, trackname = reaper.GetUserInputs( "Clone", 1,"Track Name", "" )
  if (trim(trackname)=="") then
    reaper.ShowConsoleMsg("Must enter a name"); 
    return
  end
  path=reaper.get_ini_file()
  for line in io.lines(path) do 
    ouch=trim(line)
    if (string.starts(line,"defsavepath")) then
    projpath=string.sub(line,13,string.len(line))
    end
  end
   result = runInPath(projpath,"trackclone "..trackname);
   reaper.Main_openProject(projpath..s..trackname..s..trackname..".RPP");
end

function refresh()
  name,server,username=getPrefs();
  --println(name);
  maybeSetupRepo();
  checkDuplicates(name);
  checkOrphans(name);
  encodeFilesInPart(name);
  refreshAudio()
  writePart(name);
  syncRepo();
  pushAudio(name);
  refreshTracks();
  maybeCreateTrack(name);
end

function getIndex(guid)
  local track;
  for trackNum=0,reaper.GetNumTracks()-1 do
    track=reaper.GetTrack(0,trackNum);
    if reaper.GetTrackGUID(track)==guid then
      return trackNum
    end
  end
  return 0;
end

function addTrack(index,xml,doIndentHome)
    reaper.InsertTrackAtIndex(index,false);
    track = reaper.GetTrack(0,index);
    reaper.SetTrackStateChunk(track,xml,false);
    if doIndentHome~=nil then
       if doIndentHome then
          indentHome(index);
       end
    end
end

function addAllChildren(trackNum,root,tracks,parents,prevs)
  if (root==nil) then return end
  printArray(root);
  for k,v in pairs(root) do
    addAllChildren(trackNum+1,parents[k],tracks,parents,prevs);
  end
end

function addNext(root)
  local index=getIndex(root)+1;
  --println(root);
  if (prevs[root]~=nil) then 
  for k,v in pairs(prevs[root]) do
    addTrack(index,tracks[k])
    addNext(k);
  end
  end
end


function importPart(name)
  local trackNum = deletePart(name);
  local tracks,parents,prevs=readPart(name,0);
  local root = prevs["-1"];
  prevguid="-1";
  if root~=nil then
  for k,v in pairs(root) do
    addTrack(trackNum,tracks[k],true);
    addNext(k);
  end
  end
  
 -- addAllChildren(trackNum, root,tracks,parents,prevs);
end
--refresh("PraveshVocal");
--writePart("Chiraag");
--writePart("PraveshVocal");
refresh();
println("Project Refreshed");
--encodeFilesInPart("Pravesh");
--checkDuplicates("Pravesh");
--checkOrphans("Pravesh");
--runSilentlyInPath(projectPath,"touch test.txt");
--val = isOnServer()
--if (val) then
--  println("true");
--  else
--  println("false");
--  end
--refreshTracks();
--importPart("Chiraag");
--importPart("Pravesh");
--importPart("Mags");
--refresh();
println("Sync complete");
--setup()
--init()
--copyFilesInPart("Pravesh");
--dealWithItems();
--refresh();
--writePart("Pravesh");
--refreshPart("Chiraag");
--push();
--deletePart("Pravesh");
--trackclone()
--trackToString();
-- reload();
