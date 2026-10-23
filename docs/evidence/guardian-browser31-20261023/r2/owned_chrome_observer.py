"""Observe Chrome arguments only inside the exact command's owned child tree."""
from pathlib import Path
import os
import threading
import time
from urllib.parse import urlparse
import psutil


class OwnedChromeObserver:
    def __init__(self, command_pid, chrome_executable, temporary_root):
        self.command_pid = command_pid
        self.command_created = psutil.Process(command_pid).create_time()
        self.chrome_executable = os.path.normcase(str(Path(chrome_executable)))
        self.temporary_root = Path(temporary_root)
        self.launch_time = self.command_created
        self.roots = {}
        self.problems = set()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._watch, daemon=True)

    def start(self):
        self.thread.start()

    def _watch(self):
        while not self.stop.is_set():
            try:
                owner = psutil.Process(self.command_pid)
                if owner.create_time() != self.command_created:
                    self.problems.add('Owned command PID creation identity changed')
                    break
                children = owner.children(recursive=True)
            except psutil.NoSuchProcess:
                break
            except Exception as error:
                self.problems.add('Owned child enumeration: ' + type(error).__name__)
                break
            for process in children:
                try:
                    if process.name().lower() != 'chrome.exe':
                        continue
                    arguments = process.cmdline()
                    if any(argument.startswith('--type=') for argument in arguments):
                        continue
                    created = process.create_time()
                    key = (process.pid, created)
                    if key in self.roots:
                        continue
                    if os.path.normcase(process.exe()) != self.chrome_executable or created < self.launch_time - .001:
                        raise ValueError('Chrome executable or creation ownership differs')
                    profiles = [argument.split('=',1)[1] for argument in arguments if argument.startswith('--user-data-dir=')]
                    ports = [argument.split('=',1)[1] for argument in arguments if argument.startswith('--remote-debugging-port=')]
                    if len(profiles) != 1 or len(ports) != 1 or not ports[0].isdigit() or not 0 < int(ports[0]) < 65536:
                        raise ValueError('Missing private Chrome profile or debugging port')
                    profile = Path(profiles[0])
                    if not profile.is_absolute() or not profile.is_relative_to(self.temporary_root) or profile == self.temporary_root:
                        raise ValueError('Chrome profile escaped this attempt temporary directory')
                    for parent in (profile, *profile.parents):
                        if parent.exists() and (parent.is_symlink() or parent.is_junction()):
                            raise ValueError('Chrome profile uses a linked directory')
                        if parent == self.temporary_root:
                            break
                    if not any(argument == '--headless' or argument.startswith('--headless=') for argument in arguments):
                        raise ValueError('The owned Chrome root is not headless')
                    origins=[]
                    for argument in arguments:
                        if argument.startswith(('http://','https://')):
                            url=urlparse(argument)
                            if url.scheme != 'http' or url.hostname not in ('localhost','127.0.0.1','::1') or not url.port:
                                raise ValueError('Owned Chrome test target is not a local temporary server')
                            origins.append(url.scheme+'://'+url.netloc)
                    if not origins:
                        raise ValueError('Owned Chrome root lacks its local test server target')
                    self.roots[key]={'pid':process.pid,'created':created,'executable':self.chrome_executable,
                        'profile':str(profile),'debuggingPort':int(ports[0]),'testServerOrigins':origins,
                        'headless':True,'observedOnlyAsOwnedCommandDescendant':True}
                except psutil.NoSuchProcess:
                    continue
                except Exception as error:
                    self.problems.add(type(error).__name__+': '+str(error))
            self.stop.wait(.05)

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=1)
        if self.thread.is_alive():
            self.problems.add('Owned Chrome observation thread did not stop')
        rows=list(self.roots.values())
        if not rows:
            self.problems.add('No owned Chrome root was observed')
        if len({row['profile'] for row in rows}) != len(rows):
            self.problems.add('Owned Chrome roots reused a profile')
        return {'status':'OWNED_CHROME_ARGUMENTS_OBSERVED' if not self.problems else 'NOT_ACCEPTED',
                'chromeRoots':rows,'problems':sorted(self.problems),
                'userChromeInspectedOrStopped':False,'entireChromeInstallationPinned':False,
                'loopbackDebugBindingInferredFromPinnedFlutterLauncher':True}
