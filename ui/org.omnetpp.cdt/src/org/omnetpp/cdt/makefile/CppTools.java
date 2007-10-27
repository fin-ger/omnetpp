package org.omnetpp.cdt.makefile;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.eclipse.core.resources.IContainer;
import org.eclipse.core.resources.IFile;
import org.eclipse.core.resources.IResource;
import org.eclipse.core.resources.IResourceVisitor;
import org.eclipse.core.runtime.CoreException;
import org.eclipse.core.runtime.IPath;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.Path;
import org.omnetpp.common.util.FileUtils;
import org.omnetpp.common.util.StringUtils;

/**
 * Scans all C++ files, etc....
 * TODO
 *  
 * @author Andras
 */
public class CppTools {
    /**
     * Represents an #include in a C++ file
     */
    public static class Include {
        public String filename;
        public boolean isSysInclude; // true: <foo.h>, false: "foo.h" 

        public Include(String filename, boolean isSysInclude) {
            this.isSysInclude = isSysInclude;
            this.filename = filename;
        }

        @Override
        public String toString() {
            return isSysInclude ? ("<" + filename + ">") : ("\"" + filename + "\"");
        }

        @Override
        public int hashCode() {
            final int prime = 31;
            int result = 1;
            result = prime * result + ((filename == null) ? 0 : filename.hashCode());
            result = prime * result + (isSysInclude ? 1231 : 1237);
            return result;
        }

        @Override
        public boolean equals(Object obj) {
            if (this == obj)
                return true;
            if (obj == null)
                return false;
            if (getClass() != obj.getClass())
                return false;
            final Include other = (Include) obj;
            if (filename == null) {
                if (other.filename != null)
                    return false;
            }
            else if (!filename.equals(other.filename))
                return false;
            if (isSysInclude != other.isSysInclude)
                return false;
            return true;
        }
    }

    public void generateMakefiles(IContainer container, IProgressMonitor monitor) throws CoreException {
        Map<IFile, List<Include>> fileIncludes = processFilesIn(container, monitor);
        Map<IContainer,List<IContainer>> deps = calculateDependencies(fileIncludes);
        
        for (IContainer folder : deps.keySet()) {
            System.out.print("Folder " + folder.getFullPath().toString() + " depends on: ");
            for (IContainer dep : deps.get(folder)) {
                System.out.print(" " + makeRelativePath(folder.getFullPath(), dep.getFullPath()).toString());
            }
            System.out.println();
        }
    }

    /**
     * For each folder, it determines which other folders it depends on (i.e. includes files from).
     */
    public static Map<IContainer,List<IContainer>> calculateDependencies(Map<IFile,List<Include>> fileIncludes) {
        // build a hash table of all files, for easy lookup by name
        Map<String,List<IFile>> filesByName = new HashMap<String, List<IFile>>();
        for (IFile file : fileIncludes.keySet()) {
            String name = file.getName();
            if (!filesByName.containsKey(name))
                filesByName.put(name, new ArrayList<IFile>());
            filesByName.get(name).add(file);
        }

        // process each file, and gradually expand dependencies list
        Map<IContainer,List<IContainer>> result = new HashMap<IContainer,List<IContainer>>();
        Set<Include> unresolvedIncludes = new HashSet<Include>();
        Set<Include> ambiguousIncludes = new HashSet<Include>();
        for (IFile file : fileIncludes.keySet()) {
            IContainer container = file.getParent();
            if (!result.containsKey(container))
                result.put(container, new ArrayList<IContainer>());
            List<IContainer> currentDeps = result.get(container);
            
            for (Include include : fileIncludes.get(file)) {
                if (include.filename.contains("/")) {
                    // deal with it separately. interpret as relative path to the current file?
                }
                else {
                    // determine which IFile(s) the include maps to
                    List<IFile> list = filesByName.get(include.filename);
                    if (list == null || list.isEmpty()) {
                        // oops, included file not found. what do we do?
                        unresolvedIncludes.add(include);
                    }
                    else if (list.size() > 1) {
                        // oops, ambiguous include file.  what do we do?
                        ambiguousIncludes.add(include);
                    }
                    else {
                        // include resolved successfully and unambiguously
                        IFile includedFile = list.get(0);

                        // add its folder to the dependent folders
                        IContainer dependentContainer = includedFile.getParent();
                        if (!currentDeps.contains(dependentContainer))
                            currentDeps.add(dependentContainer);
                    }
                }
            }
        }

        System.out.println("includes not found: " + StringUtils.join(unresolvedIncludes, " "));
        System.out.println("ambiguous includes: " + StringUtils.join(ambiguousIncludes, " "));

        //TODO calculate transitive closure here...
        
        return result;
    }

    public static Map<IFile,List<Include>> processFilesIn(IContainer container, final IProgressMonitor monitor) throws CoreException {
        final Map<IFile,List<Include>> result = new HashMap<IFile,List<Include>>();
        container.accept(new IResourceVisitor() {
            public boolean visit(IResource resource) throws CoreException {
                if (isCppFile(resource)) {
                    monitor.subTask(resource.getFullPath().toString());
                    try {
                        IFile file = (IFile)resource;
                        List<Include> includes = CppTools.parseIncludes(file);
                        result.put(file, includes);
                    }
                    catch (IOException e) {
                        throw new RuntimeException("Could not process file " + resource.getFullPath().toString(), e);
                    }
                    monitor.worked(1);
                }
                if (monitor.isCanceled())
                    return false;
                return true;
            }
        });
        return result;
    }

    public static boolean isCppFile(IResource resource) {
        if (resource instanceof IFile) {
            //TODO: ask CDT about registered file extensions?
            String fileExtension = ((IFile)resource).getFileExtension();
            if ("cc".equalsIgnoreCase(fileExtension) || "cpp".equals(fileExtension) || "h".equals(fileExtension))
                return true;
        }
        return false;
    }
    
    public static IPath makeRelativePath(IPath base, IPath target) {
        int commonPrefixLen = target.matchingFirstSegments(base);
        int upLevels = base.segmentCount() - commonPrefixLen;
        return new Path(StringUtils.repeat("../", upLevels)).append(target.removeFirstSegments(commonPrefixLen));
    }

    /**
     * Collect #includes from a C++ source file
     */
    public static List<Include> parseIncludes(IFile file) throws CoreException, IOException {
        String contents = FileUtils.readTextFile(file.getContents()) + "\n";
        return parseIncludes(contents);
    }

    /**
     * Collect #includes from C++ source file contents
     */
    public static List<Include> parseIncludes(String source) {
        List<Include> result = new ArrayList<Include>();
        Matcher matcher = Pattern.compile("(?m)^\\s*#\\s*include\\s+([\"<])(.*?)[\">].*$").matcher(source);
        while (matcher.find()) {
            boolean isSysInclude = matcher.group(1).equals("<");
            String fileName = matcher.group(2);
            result.add(new Include(fileName.trim().replace('\\','/'), isSysInclude));
        }
        return result;
    }


}
