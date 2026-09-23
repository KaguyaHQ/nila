import { createContext, useContext, useState, type ReactNode } from "react";

type UploadPreview = {
  files: File[];
  addFiles: (files: File[]) => void;
  removeFile: (index: number) => void;
  clearFiles: () => void;
};
const Context = createContext<UploadPreview | null>(null);

export function UploadPreviewProvider({ children }: { children: ReactNode }) {
  const [files, setFiles] = useState<File[]>([]);
  const addFiles = (incoming: File[]) =>
    setFiles((current) => {
      const next = [...current];
      for (const file of incoming) {
        if (
          !next.some(
            (existing) =>
              existing.name === file.name &&
              existing.size === file.size &&
              existing.lastModified === file.lastModified,
          )
        ) {
          next.push(file);
        }
      }
      return next;
    });
  return (
    <Context.Provider
      value={{
        files,
        addFiles,
        removeFile: (index) => setFiles((current) => current.filter((_, i) => i !== index)),
        clearFiles: () => setFiles([]),
      }}
    >
      {children}
    </Context.Provider>
  );
}

export function useUploadPreview() {
  const context = useContext(Context);
  if (!context) throw new Error("UploadPreviewProvider is required");
  return context;
}
